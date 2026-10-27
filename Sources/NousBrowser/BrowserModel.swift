import AppKit
import Foundation
import Observation
import WebKit

nonisolated enum SidebarSizing {
    static let defaultWidth: Double = 243
    static let minimumWidth: Double = 180
    static let maximumWidth: Double = 420
    static let minimumPageWidth: Double = 320

    static func clampedWidth(_ width: Double) -> Double {
        guard width.isFinite else { return defaultWidth }
        return min(maximumWidth, max(minimumWidth, width))
    }

    /// A narrow window temporarily limits the rendered sidebar without changing
    /// the user's preferred width, which can be restored when the window grows.
    static func effectiveWidth(preferred: Double, windowWidth: Double) -> Double {
        let availableWidth = windowWidth.isFinite
            ? max(minimumWidth, windowWidth - minimumPageWidth)
            : maximumWidth
        return min(clampedWidth(preferred), availableWidth)
    }
}

/// Tabs are restored separately from WebKit's persistent cookie and website-data store.
/// Credentials are never serialized into this file.
struct BrowserSession: Codable, Equatable {
    struct Tab: Codable, Equatable {
        var id: UUID
        var title: String
        var url: URL?
        var isPinned: Bool

        init(id: UUID, title: String, url: URL?, isPinned: Bool = false) {
            self.id = id
            self.title = title
            self.url = url
            self.isPinned = isPinned
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, url, isPinned
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            url = try container.decodeIfPresent(URL.self, forKey: .url)
            // Earlier sessions have no pin preference; preserve all their tabs.
            isPinned = (try? container.decode(Bool.self, forKey: .isPinned)) ?? false
        }
    }

    var tabs: [Tab]
    var selectedTabID: UUID?
    var isSidebarVisible: Bool
    var sidebarWidth: Double

    init(tabs: [Tab], selectedTabID: UUID?, isSidebarVisible: Bool, sidebarWidth: Double = SidebarSizing.defaultWidth) {
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.isSidebarVisible = isSidebarVisible
        self.sidebarWidth = sidebarWidth
    }

    private enum CodingKeys: String, CodingKey {
        case tabs, selectedTabID, isSidebarVisible, sidebarWidth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try container.decode([Tab].self, forKey: .tabs)
        selectedTabID = try container.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        isSidebarVisible = try container.decode(Bool.self, forKey: .isSidebarVisible)
        // Layout preferences are optional for sessions written by earlier builds.
        // An invalid layout value must not discard the user's tabs either.
        sidebarWidth = (try? container.decode(Double.self, forKey: .sidebarWidth)) ?? SidebarSizing.defaultWidth
    }
}

@MainActor
@Observable
final class BrowserModel {
    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedTabID: UUID? {
        didSet {
            guard oldValue != selectedTabID else { return }
            // Both the tab being left and the one shown were in use until now.
            let now = now()
            for tab in tabs where tab.id == oldValue || tab.id == selectedTabID { tab.lastActiveAt = now }
        }
    }
    private(set) var sidebarWidth = SidebarSizing.defaultWidth
    var isSidebarVisible = true {
        didSet { scheduleSave() }
    }

    @ObservationIgnored private let sessionURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var closedTabs: [BrowserSession.Tab] = []
    @ObservationIgnored private var isRestoring = true
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored var onLastTabClosed: (() -> Void)?
    @ObservationIgnored var onVisit: ((URL, String) -> Void)?
    @ObservationIgnored var onPageTitleChanged: ((URL, String) -> Void)?
    @ObservationIgnored var onOpenLinkInNewWindow: ((URL) -> Void)?
    @ObservationIgnored var searchEngineProvider: () -> BrowserSearchEngine = { .google }
    /// Injectable so tests can age tabs without waiting.
    @ObservationIgnored var now: () -> Date = Date.init

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabID } }
    var addressDisplay: String { selectedTab?.url?.absoluteString ?? "" }
    var canRestoreClosedTab: Bool { !closedTabs.isEmpty }

    init(sessionURL: URL? = nil, restoreSession: Bool = true, loadSelectedTab: Bool = true, startWithBlankTab: Bool = false,
         initialTab: BrowserTab? = nil) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nous Browser", isDirectory: true)
        self.sessionURL = sessionURL ?? directory.appendingPathComponent("session.json")
        if let initialTab {
            tabs = [initialTab]
            selectedTabID = initialTab.id
            initialTab.owner = self
        } else if restoreSession,
           let data = try? Data(contentsOf: self.sessionURL),
           let session = try? JSONDecoder().decode(BrowserSession.self, from: data),
           !session.tabs.isEmpty {
            let orderedTabs = session.tabs.filter(\.isPinned) + session.tabs.filter { !$0.isPinned }
            tabs = orderedTabs.map { BrowserTab(id: $0.id, title: $0.title, url: $0.url, isPinned: $0.isPinned, owner: self) }
            selectedTabID = tabs.contains(where: { $0.id == session.selectedTabID }) ? session.selectedTabID : tabs.first?.id
            isSidebarVisible = session.isSidebarVisible
            sidebarWidth = SidebarSizing.clampedWidth(session.sidebarWidth)
        } else {
            let tab = startWithBlankTab
                ? BrowserTab(owner: self)
                : BrowserTab(title: "Apple", url: URL(string: "https://www.apple.com"), owner: self)
            tabs = [tab]
            selectedTabID = tab.id
        }
        isRestoring = false
        if loadSelectedTab, initialTab == nil { selectedTab?.loadIfNeeded() }
    }

    func newTab(url: URL? = nil) {
        let tab = BrowserTab(url: url, owner: self)
        tabs.append(tab)
        selectedTabID = tab.id
        tab.loadIfNeeded()
        persistSession()
    }

    @discardableResult
    func openLinkInNewTab(_ url: URL, after sourceID: UUID) -> BrowserTab? {
        guard !isShutDown, Self.canOpenExternalURL(url),
              let source = tabs.firstIndex(where: { $0.id == sourceID }) else { return nil }
        let tab = BrowserTab(url: url, owner: self)
        // Links from a pinned page start the normal group, like duplicated pins.
        tabs.insert(tab, at: tabs[source].isPinned ? firstNormalTabIndex : source + 1)
        selectedTabID = tab.id
        tab.loadIfNeeded()
        persistSession()
        return tab
    }

    func openLinkInNewWindow(_ url: URL, from sourceID: UUID? = nil) {
        guard !isShutDown, Self.canOpenExternalURL(url),
              sourceID == nil || tabs.contains(where: { $0.id == sourceID }) else { return }
        onOpenLinkInNewWindow?(url)
    }

    /// A transfer changes ownership without closing, pausing or reloading the page.
    /// The manager saves the destination first, then this source session.
    func takeTabForTransfer(_ id: UUID) -> BrowserTab? {
        guard !isShutDown, let index = tabs.firstIndex(where: { $0.id == id }),
              tabs[index].webView.fullscreenState == .notInFullscreen else { return nil }
        let tab = tabs.remove(at: index)
        tab.owner = nil
        tab.webView.removeFromSuperview()
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
            selectedTab?.loadIfNeeded()
        }
        return tab
    }

    func canAdoptTransferredTab(withID id: UUID) -> Bool {
        !isShutDown && !tabs.contains(where: { $0.id == id })
    }

    /// `index` is an insertion slot in the destination before the transfer.
    /// Keep the incoming pin status and the existing tabs' relative order.
    @discardableResult
    func adoptTransferredTab(_ tab: BrowserTab, at index: Int) -> Bool {
        guard tab.owner == nil, canAdoptTransferredTab(withID: tab.id) else { return false }
        let boundary = firstNormalTabIndex
        let destination = tab.isPinned
            ? min(boundary, max(0, index))
            : min(tabs.count, max(boundary, index))
        tab.owner = self
        tabs.insert(tab, at: destination)
        selectedTabID = tab.id
        persistSession()
        return true
    }

    func selectTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedTabID = id
        tab.loadIfNeeded()
        persistSession()
    }

    func duplicateTab(_ id: UUID) {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == id }) else { return }
        let source = tabs[sourceIndex]
        let duplicate = BrowserTab(title: source.title, url: source.url, owner: self)
        duplicate.title = source.title
        // A duplicated pinned page is a normal tab below the pinned group.
        // Normal pages duplicate directly beside their source.
        let index = source.isPinned ? firstNormalTabIndex : sourceIndex + 1
        tabs.insert(duplicate, at: index)
        selectedTabID = duplicate.id
        duplicate.loadIfNeeded()
        persistSession()
    }

    func togglePin(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        tab.isPinned.toggle()
        tabs.insert(tab, at: tab.isPinned ? 0 : firstNormalTabIndex)
        // Keep the selected tab and each live WebView intact while reordering.
        persistSession()
    }

    func moveTab(_ id: UUID, to destination: Int) {
        let order = tabs.map(\.id)
        let pinnedIDs = Set(tabs.filter(\.isPinned).map(\.id))
        guard let source = tabs.firstIndex(where: { $0.id == id }),
              let destination = TabReordering.destinationIndex(for: id, in: order, pinnedIDs: pinnedIDs, proposedIndex: destination),
              source != destination else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: destination)
        persistSession()
    }

    private var firstNormalTabIndex: Int { tabs.firstIndex { !$0.isPinned } ?? tabs.count }

    func closeTab(_ id: UUID) {
        guard !isShutDown, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count == 1, let onLastTabClosed {
            // The window owns the final tab's lifetime and saves its intact
            // session during shutdown. Standalone models retain the fallback.
            onLastTabClosed()
            return
        }
        let tab = tabs[index]
        closedTabs.append(.init(id: tab.id, title: tab.title, url: tab.url, isPinned: tab.isPinned))
        if closedTabs.count > 20 { closedTabs.removeFirst() }
        tab.cancelFaviconLoading()
        tab.detachPageNavigationShortcuts()
        (tab.webView as? BrowserWebView)?.invalidateContextMenu()
        let closingWebView = tab.webView
        closingWebView.stopLoading()
        closingWebView.pauseAllMediaPlayback(completionHandler: nil)
        closingWebView.closeAllMediaPresentations { [closingWebView] in
            // Let WebKit restore its own fullscreen view hierarchy first.
            // Capture the old view, since reopening a tab can reuse its ID.
            closingWebView.removeFromSuperview()
        }
        tabs.remove(at: index)
        if tabs.isEmpty {
            newTab()
        } else if selectedTabID == id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
            selectedTab?.loadIfNeeded()
        }
        persistSession()
    }

    func navigate(_ input: String, searchEngine: BrowserSearchEngine = .google) {
        guard let url = Self.normalizeAddress(input, searchEngine: searchEngine) else { return }
        if selectedTab == nil { newTab(url: url) }
        else { selectedTab?.load(url) }
        persistSession()
    }

    /// Launch Services may deliver both website URLs and HTML documents.
    /// Other files and arbitrary application schemes are outside this handler.
    nonisolated static func canOpenExternalURL(_ url: URL) -> Bool {
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return !(url.host ?? "").isEmpty
        }
        return url.isFileURL && !url.hasDirectoryPath
            && ["html", "htm", "xhtml"].contains(url.pathExtension.lowercased())
    }

    /// Safari's explicit HTTPS wrapper still represents a website. Resolve
    /// that known format internally instead of sending it to Launch Services.
    nonisolated static func unwrappedSafariWebsite(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "x-safari-https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        components.scheme = "https"
        return components.url
    }

    /// Supports URL entry, localhost development addresses, and ordinary search queries.
    /// Active-content and file schemes cannot be entered through the address field.
    nonisolated static func normalizeAddress(_ input: String, searchEngine: BrowserSearchEngine = .google) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = BrowserAddressInput.websiteURL(for: text) { return url }
        let lower = text.lowercased()
        if text.contains("://") || lower.hasPrefix("javascript:") || lower.hasPrefix("data:") || lower.hasPrefix("file:") {
            return nil
        }
        return searchEngine.searchURL(query: text)
    }

    func goBack() { selectedTab?.webView.goBack() }
    func goForward() { selectedTab?.webView.goForward() }
    func reload(bypassingCache: Bool = false) {
        guard let tab = selectedTab else { return }
        let failed = tab.errorDescription != nil
        tab.errorDescription = nil
        if failed || tab.webView.url == nil {
            guard let url = tab.url else { return }
            tab.load(url, cachePolicy: bypassingCache ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy)
        } else if bypassingCache {
            // Revalidate with the origin without clearing cookies or website data.
            tab.webView.reloadFromOrigin()
        } else { tab.webView.reload() }
    }
    func stopLoading() { selectedTab?.webView.stopLoading() }
    func toggleSidebar() { isSidebarVisible.toggle() }

    private static let zoomLevels: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]

    func zoomIn() {
        guard let tab = selectedTab, tab.hasWebContent else { return }
        tab.webView.pageZoom = Self.zoomLevels.first { $0 > tab.webView.pageZoom + 0.001 } ?? Self.zoomLevels.last!
    }

    func zoomOut() {
        guard let tab = selectedTab, tab.hasWebContent else { return }
        tab.webView.pageZoom = Self.zoomLevels.last { $0 < tab.webView.pageZoom - 0.001 } ?? Self.zoomLevels.first!
    }

    func resetZoom() {
        guard let tab = selectedTab, tab.hasWebContent else { return }
        tab.webView.pageZoom = 1
    }

    func resizeSidebar(to width: Double) {
        let width = SidebarSizing.clampedWidth(width)
        guard sidebarWidth != width else { return }
        sidebarWidth = width
        scheduleSave()
    }

    func resetSidebarWidth() { resizeSidebar(to: SidebarSizing.defaultWidth) }

    func restoreClosedTab() {
        guard let saved = closedTabs.popLast() else { return }
        let tab = BrowserTab(id: saved.id, title: saved.title, url: saved.url, isPinned: saved.isPinned, owner: self)
        tabs.insert(tab, at: tab.isPinned ? firstNormalTabIndex : tabs.count)
        selectedTabID = tab.id
        tab.loadIfNeeded()
        persistSession()
    }

    func selectNextTab(backward: Bool = false) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        let next = (current + (backward ? -1 : 1) + tabs.count) % tabs.count
        selectTab(tabs[next].id)
    }

    /// Browser convention: 1–8 select a position; 9 always selects the last tab.
    func selectTab(number: Int) {
        guard (1...9).contains(number) else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index].id)
    }

    func persistSession() {
        guard !isRestoring, !isShutDown else { return }
        saveTask?.cancel()
        let session = BrowserSession(
            tabs: tabs.map { .init(id: $0.id, title: $0.title, url: Self.persistableURL($0.url), isPinned: $0.isPinned) },
            selectedTabID: selectedTabID,
            isSidebarVisible: isSidebarVisible,
            sidebarWidth: sidebarWidth
        )
        do {
            try FileManager.default.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(session)
            try data.write(to: sessionURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionURL.path)
        } catch {
            NSLog("Nous Browser: Could not save tab session: %@", error.localizedDescription)
        }
    }

    fileprivate func scheduleSave() {
        guard !isRestoring, !isShutDown else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.persistSession()
        }
    }

    /// Closing a window preserves its final session without closing its tabs
    /// one by one or allowing late WebKit observations to rewrite the snapshot.
    func shutdown() {
        guard !isShutDown else { return }
        persistSession()
        isShutDown = true
        onLastTabClosed = nil
        onVisit = nil
        onPageTitleChanged = nil
        onOpenLinkInNewWindow = nil
        saveTask?.cancel()
        saveTask = nil
        tabs.forEach { $0.shutdown() }
    }

    fileprivate func recordVisit(_ url: URL, title: String) {
        guard !isShutDown else { return }
        onVisit?(url, title)
    }

    fileprivate func recordPageTitleChange(_ url: URL, title: String) {
        guard !isShutDown else { return }
        onPageTitleChanged?(url, title)
    }

    /// Strip embedded basic-auth credentials before storing an address on disk.
    nonisolated private static func persistableURL(_ url: URL?) -> URL? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.user = nil
        components.password = nil
        return components.url
    }

    /// Unloads background pages chosen by `TabHibernation`. Pages playing audio
    /// or video are skipped; asking WebKit for that state is asynchronous.
    @discardableResult
    func hibernateBackgroundTabs(for pressure: TabHibernation.Pressure) async -> [UUID] {
        guard !isShutDown else { return [] }
        let candidates = tabs.map {
            TabHibernation.Candidate(id: $0.id, isSelected: $0.id == selectedTabID, isPinned: $0.isPinned,
                                     isLoaded: $0.isHibernatable, isCapturingMedia: $0.isCapturingMedia,
                                     lastActiveAt: $0.lastActiveAt)
        }
        var hibernated: [UUID] = []
        for id in TabHibernation.tabsToHibernate(candidates, pressure: pressure, now: now()) {
            guard let tab = tabs.first(where: { $0.id == id }) else { continue }
            let playback = await tab.webView.requestMediaPlaybackState()
            // The tab may have been shown or closed while WebKit answered.
            guard !isShutDown else { return hibernated }
            guard playback != .playing, tabs.contains(where: { $0 === tab }), selectedTabID != id else { continue }
            tab.hibernate()
            hibernated.append(id)
        }
        return hibernated
    }

    fileprivate func openPopup(configuration: WKWebViewConfiguration, after sourceID: UUID) -> WKWebView {
        let tab = BrowserTab(owner: self, configuration: configuration)
        let index = tabs.firstIndex { $0.id == sourceID }
        let destination = index.map { tabs[$0].isPinned ? firstNormalTabIndex : $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: destination)
        selectedTabID = tab.id
        persistSession()
        return tab.webView
    }
}

@MainActor
@Observable
final class BrowserTab: NSObject, Identifiable {
    let id: UUID
    var title: String
    var url: URL?
    fileprivate(set) var isPinned: Bool
    var isLoading = false
    var estimatedProgress = 0.0
    var canGoBack = false
    var canGoForward = false
    var errorDescription: String?
    var favicon: NSImage?
    var passwordCandidate: BrowserPasswordAutofill.Candidate?
    /// A popup may render document.write content at about:blank without a URL.
    var hasWebContent: Bool
    /// Replaced by a fresh, unloaded view when the tab hibernates.
    private(set) var webView: WKWebView
    /// The page was unloaded to free memory and is restored when shown again.
    private(set) var isHibernated = false
    /// When this tab was last shown; background tabs hibernate after long idle periods.
    @ObservationIgnored var lastActiveAt = Date()

    @ObservationIgnored fileprivate weak var owner: BrowserModel?
    func isOwned(by model: BrowserModel) -> Bool { owner === model }
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var pendingInteractionState: Any?
    @ObservationIgnored private var needsReloadAfterTermination = false
    @ObservationIgnored private var lastTerminationReload: Date?
    @ObservationIgnored private var faviconTask: Task<Void, Never>?
    @ObservationIgnored private var faviconPageURL: URL?
    @ObservationIgnored private var faviconRequestID = UUID()
    @ObservationIgnored private var faviconObservation: BrowserFaviconObservation.Attachment?
    @ObservationIgnored private var passwordAutofill: BrowserPasswordAutofill.Attachment?
    @ObservationIgnored private var pageNavigationShortcuts: BrowserPageNavigationShortcuts.Attachment?
    @ObservationIgnored private var userAgentPolicy: BrowserUserAgent.NavigationPolicy?

    var displayTitle: String {
        !hasWebContent && url == nil ? L10n.string("New Tab") : title
    }

    init(id: UUID = UUID(), title: String? = nil, url: URL? = nil, isPinned: Bool = false, owner: BrowserModel?, configuration: WKWebViewConfiguration? = nil) {
        self.id = id
        self.isPinned = isPinned
        // A restored empty tab follows the current language, even when its
        // saved placeholder came from a previous app/system language.
        self.title = url == nil && configuration == nil
            ? L10n.string("New Tab")
            : title ?? Self.fallbackTitle(for: url) ?? L10n.string("New Tab")
        self.url = url
        self.hasWebContent = configuration != nil || url != nil
        self.owner = owner
        webView = Self.makeWebView(configuration: configuration)
        super.init()
        attach(webView)
        if let url { refreshFavicon(for: url) }
    }

    private static func makeWebView(configuration: WKWebViewConfiguration?) -> WKWebView {
        let config = configuration ?? WKWebViewConfiguration()
        if configuration == nil { config.websiteDataStore = .default() }
        // WebKit's popup blocker: link targets and window.open during a click
        // or key press still open tabs; scripts without user activation cannot.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Lets video players and other pages use the HTML Fullscreen API.
        config.preferences.isElementFullscreenEnabled = true
        BrowserScrollbars.install(in: config)
        BrowserUserAgent.configure(config)
        BrowserPasswordAutofill.install(configuration: config)
        BrowserPageNavigationShortcuts.install(in: config)
        BrowserFaviconObservation.install(in: config)
        return BrowserWebView(frame: .zero, configuration: config)
    }

    private func attach(_ webView: WKWebView) {
        userAgentPolicy = BrowserUserAgent.NavigationPolicy(webView: webView)
        faviconObservation = BrowserFaviconObservation.attach(to: webView) { [weak self, weak webView] snapshot in
            guard let self, self.webView === webView, self.url == snapshot.pageURL else { return }
            self.updateFavicon(snapshot)
        }
        if let browserView = webView as? BrowserWebView {
            browserView.onOpenLinkInNewTab = { [weak self, weak webView] url in
                guard let self, self.webView === webView else { return }
                self.owner?.openLinkInNewTab(url, after: self.id)
            }
            browserView.onOpenLinkInNewWindow = { [weak self, weak webView] url in
                guard let self, self.webView === webView else { return }
                self.owner?.openLinkInNewWindow(url, from: self.id)
            }
            browserView.searchEngineTitle = { [weak self] in self?.owner?.searchEngineProvider().title ?? BrowserSearchEngine.google.title }
            browserView.onSearchSelection = { [weak self, weak webView] text in
                guard let self, self.webView === webView, let owner = self.owner else { return }
                owner.openLinkInNewTab(owner.searchEngineProvider().searchURL(query: text), after: self.id)
            }
        }
        pageNavigationShortcuts = BrowserPageNavigationShortcuts.attach(to: webView) { [weak self, weak webView] direction in
            guard let self, let webView, self.webView === webView,
                  let owner = self.owner, owner.selectedTab === self,
                  let window = webView.window, window.isKeyWindow, window.attachedSheet == nil,
                  let responder = window.firstResponder as? NSView,
                  responder === webView || responder.isDescendant(of: webView),
                  webView.inputContext == nil else { return }
            if let controller = (window as? BrowserWindow)?.browserController {
                guard controller.model === owner, !controller.isAddressPresented, !controller.passwords.isPresented else { return }
            }
            switch direction {
            case .back: if self.canGoBack { owner.goBack() }
            case .forward: if self.canGoForward { owner.goForward() }
            }
        }
        passwordAutofill = BrowserPasswordAutofill.attach(to: webView) { [weak self] candidate in
            self?.passwordCandidate = candidate
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = false
        webView.underPageBackgroundColor = .windowBackgroundColor
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self, view === self.webView else { return }
                    self.title = view.title.flatMap { $0.isEmpty ? nil : $0 } ?? Self.fallbackTitle(for: self.url) ?? L10n.string("New Tab")
                    if !view.isLoading, self.errorDescription == nil, let url = view.url {
                        self.owner?.recordPageTitleChange(url, title: self.title)
                    }
                    self.owner?.scheduleSave()
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self, view === self.webView else { return }
                    if let url = view.url {
                        if url.absoluteString != "about:blank" {
                            self.url = url
                            if !view.isLoading, self.errorDescription == nil {
                                self.owner?.recordVisit(url, title: self.title)
                            }
                        }
                        if self.faviconPageURL != url {
                            self.refreshFavicon(for: url)
                            // History API changes do not produce didFinish. Ask
                            // the live document for its icon after an SPA route changes.
                            if !view.isLoading { self.faviconObservation?.refresh() }
                        }
                    }
                    self.owner?.scheduleSave()
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.estimatedProgress = view.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            }
        ]
    }

    private func detachWebView() {
        cancelFaviconLoading()
        faviconObservation?.invalidate()
        faviconObservation = nil
        userAgentPolicy?.invalidate()
        userAgentPolicy = nil
        (webView as? BrowserWebView)?.invalidateContextMenu()
        detachPageNavigationShortcuts()
        observations.forEach { $0.invalidate() }
        observations = []
        passwordAutofill?.invalidate()
        passwordAutofill = nil
        passwordCandidate = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    fileprivate func detachPageNavigationShortcuts() {
        pageNavigationShortcuts?.invalidate()
        pageNavigationShortcuts = nil
    }

    func prepareAfterTransfer() {
        guard errorDescription == nil else { return }
        // Live views keep their DOM/history untouched. Only an unloaded page
        // needs its first load or its hibernated interaction state restored.
        if isHibernated || (!hasLoaded && webView.url == nil && !webView.isLoading) { loadIfNeeded() }
    }

    func loadIfNeeded(force: Bool = false) {
        if needsReloadAfterTermination {
            reloadAfterTermination()
            return
        }
        if !hasLoaded, !force, let state = pendingInteractionState {
            // Restores the back/forward list and reloads its current page.
            pendingInteractionState = nil
            isHibernated = false
            hasLoaded = true
            webView.interactionState = state
            return
        }
        guard (!hasLoaded || force), let url else { return }
        load(url)
    }

    /// Whether the page is currently doing something the user would notice
    /// stopping. Audio and video playback is checked separately (it is async).
    var isCapturingMedia: Bool {
        webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none
    }

    /// Whether this tab holds a live page that hibernating would release.
    var isHibernatable: Bool { hasLoaded && !isHibernated }

    /// Releases the page and its web content process. The back/forward list and
    /// current page are kept, and come back when the tab is shown again.
    func hibernate() {
        guard isHibernatable else { return }
        let oldWebView = webView
        // Local files need loadFileURL's read access, which a restored state lacks.
        let state = url?.isFileURL == true ? nil : oldWebView.interactionState
        detachWebView()
        oldWebView.stopLoading()
        oldWebView.pauseAllMediaPlayback(completionHandler: nil)
        oldWebView.removeFromSuperview()
        webView = Self.makeWebView(configuration: nil)
        webView.pageZoom = oldWebView.pageZoom
        attach(webView)
        pendingInteractionState = state
        needsReloadAfterTermination = false
        hasLoaded = false
        isHibernated = true
        isLoading = false
        estimatedProgress = 0
        canGoBack = false
        canGoForward = false
        errorDescription = nil
    }

    /// A page whose content process ended (memory pressure or a crash) reloads
    /// when shown. Repeated failures stop and show the error instead of looping.
    private func reloadAfterTermination() {
        needsReloadAfterTermination = false
        let now = owner?.now() ?? Date()
        if let last = lastTerminationReload, now.timeIntervalSince(last) < Self.terminationReloadWindow {
            isLoading = false
            errorDescription = L10n.string("The webpage stopped responding. Reload to continue.")
            return
        }
        lastTerminationReload = now
        errorDescription = nil
        if webView.backForwardList.currentItem != nil { webView.reload() }
        else if let url { load(url) }
    }

    static let terminationReloadWindow: TimeInterval = 10

    func load(_ url: URL, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) {
        // Cancel an older identity lookup before a new address starts loading.
        // The main-frame navigation policy resolves a first compatible-site identity.
        userAgentPolicy?.applyKnownIdentity(for: url)
        let wasBlankTab = !hasWebContent && self.url == nil
        let hadPlaceholderTitle = ["New Tab", "新标签页", "新標籤頁", L10n.string("New Tab")].contains(title)
        hasLoaded = true
        hasWebContent = true
        self.url = url
        refreshFavicon(for: url)
        errorDescription = nil
        // A real website may itself be titled “New Tab”; only replace an
        // actual empty-tab placeholder when beginning its first navigation.
        if wasBlankTab && hadPlaceholderTitle { title = Self.fallbackTitle(for: url) ?? url.absoluteString }
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url, cachePolicy: cachePolicy))
        }
        owner?.scheduleSave()
    }

    nonisolated private static func fallbackTitle(for url: URL?) -> String? {
        guard let url else { return nil }
        return url.isFileURL ? url.lastPathComponent : url.host
    }

    func cancelFaviconLoading() {
        faviconTask?.cancel()
        faviconTask = nil
        faviconRequestID = UUID()
    }

    fileprivate func shutdown() {
        cancelFaviconLoading()
        detachWebView()
        owner = nil
        pendingInteractionState = nil
        webView.stopLoading()
        webView.pauseAllMediaPlayback(completionHandler: nil)
        let closingView = webView
        closingView.closeAllMediaPresentations { [closingView] in
            closingView.removeFromSuperview()
        }
    }

    private func refreshFavicon(for pageURL: URL) {
        cancelFaviconLoading()
        let changedPage = faviconPageURL != pageURL
        faviconPageURL = pageURL
        guard Self.iconOrigin(for: pageURL) != nil else {
            favicon = nil
            return
        }
        let cached = FaviconStore.shared.cachedImage(for: pageURL)
        if changedPage || favicon == nil { favicon = cached }
        let requestID = faviconRequestID
        faviconTask = Task { [weak self] in
            // Avoid starting work for tabs already discarded before this task ran.
            guard self != nil, !Task.isCancelled else { return }
            let image = await FaviconStore.shared.image(for: pageURL)
            guard !Task.isCancelled, let self, self.faviconRequestID == requestID,
                  self.url == pageURL else { return }
            if let image { self.favicon = image }
        }
    }

    nonisolated private static func iconOrigin(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }

    private func updateFavicon(_ snapshot: BrowserFaviconObservation.Snapshot) {
        let pageURL = snapshot.pageURL
        guard webView.url == pageURL, url == pageURL,
              Self.iconOrigin(for: pageURL) != nil, let observer = faviconObservation else { return }
        cancelFaviconLoading()
        faviconPageURL = pageURL
        let requestID = faviconRequestID
        faviconTask = Task { [weak self] in
            guard !Task.isCancelled, self?.faviconRequestID == requestID, observer.isCurrent(snapshot) else { return }
            for candidate in snapshot.candidates {
                guard !Task.isCancelled, self?.faviconRequestID == requestID, observer.isCurrent(snapshot) else { return }
                // WebKit renders document-generated SVG/emoji and blob icons,
                // and uses the page's authenticated image-loading context.
                let rendered = await observer.rasterize(candidate, snapshot: snapshot)
                guard !Task.isCancelled, self?.faviconRequestID == requestID, observer.isCurrent(snapshot) else { return }
                if let rendered, let image = FaviconStore.shared.storePageImage(rendered, for: pageURL, sourceURL: candidate) {
                    self?.favicon = image
                    return
                }
                // Cross-origin images may taint the canvas. Download that exact
                // declared candidate before considering the next or a site fallback.
                let image = await FaviconStore.shared.image(for: pageURL, candidates: [candidate], allowRootFallback: false)
                guard !Task.isCancelled, self?.faviconRequestID == requestID, observer.isCurrent(snapshot) else { return }
                if let image { self?.favicon = image; return }
            }
            guard !Task.isCancelled, self?.faviconRequestID == requestID, observer.isCurrent(snapshot) else { return }
            let image = await FaviconStore.shared.image(for: pageURL, usePageCache: false)
            guard !Task.isCancelled, self?.faviconRequestID == requestID, observer.isCurrent(snapshot) else { return }
            self?.favicon = image
        }
    }

    private func present(_ alert: NSAlert, completion: @escaping @MainActor @Sendable (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else { completion(alert.runModal()) }
    }
}

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        passwordCandidate = nil
        hasLoaded = true
        hasWebContent = true
        errorDescription = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        errorDescription = nil
        if let url = webView.url { owner?.recordVisit(url, title: webView.title ?? title) }
        faviconObservation?.refresh()
        owner?.scheduleSave()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        record(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { record(error) }

    private func record(_ error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled, nsError.code != 102 else { return }
        isLoading = false
        errorDescription = error.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        isLoading = false
        needsReloadAfterTermination = true
        // A background tab reloads when it is shown, like Safari; the visible one now.
        if owner?.selectedTabID == id { reloadAfterTermination() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView else { decisionHandler(.cancel); return }
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "x-safari-https" {
            decisionHandler(.cancel)
            guard navigationAction.navigationType == .linkActivated || navigationAction.sourceFrame.isMainFrame,
                  let website = BrowserModel.unwrappedSafariWebsite(url) else { return }
            if navigationAction.targetFrame?.isMainFrame == true { load(website) }
            else { owner?.openLinkInNewTab(website, after: id) }
            return
        }
        if !["https", "http", "about", "blob", "data", "file"].contains(scheme) {
            decisionHandler(.cancel)
            guard navigationAction.navigationType == .linkActivated || navigationAction.sourceFrame.isMainFrame else { return }
            let alert = NSAlert()
            alert.messageText = L10n.string("Open another app?")
            alert.informativeText = L10n.format("This webpage wants to open a link using the %@ app.", scheme)
            alert.addButton(withTitle: L10n.string("Open App"))
            alert.addButton(withTitle: L10n.string("Cancel"))
            present(alert) { response in
                if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
            }
            return
        }
        if navigationAction.modifierFlags.contains(.command), navigationAction.navigationType == .linkActivated {
            owner?.openLinkInNewTab(url, after: id)
            decisionHandler(.cancel)
            return
        }
        let policy: WKNavigationActionPolicy = navigationAction.shouldPerformDownload ? .download : .allow
        guard navigationAction.targetFrame?.isMainFrame == true, let userAgentPolicy else {
            decisionHandler(policy)
            return
        }
        userAgentPolicy.prepare(for: url) { ready in decisionHandler(ready ? policy : .cancel) }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        // A redirect can cross identity profiles without a new action callback.
        // Apply the destination profile before committing its document.
        userAgentPolicy?.applyKnownIdentity(for: webView.url)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard webView === self.webView else { decisionHandler(.cancel); return }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let isAttachment = disposition.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "attachment"
        let policy: WKNavigationResponsePolicy = isAttachment || !navigationResponse.canShowMIMEType ? .download : .allow
        guard navigationResponse.isForMainFrame, let url = navigationResponse.response.url,
              let userAgentPolicy else { decisionHandler(policy); return }
        userAgentPolicy.prepare(for: url) { ready in decisionHandler(ready ? policy : .cancel) }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest].contains(method) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.format("Sign in to %@", challenge.protectionSpace.host)
        alert.informativeText = challenge.previousFailureCount > 0
            ? L10n.string("The username or password was not accepted. Try again.")
            : L10n.string("This website requires a username and password.")
        alert.addButton(withTitle: L10n.string("Sign In"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        let username = NSTextField(frame: NSRect(x: 0, y: 34, width: 280, height: 24))
        username.placeholderString = L10n.string("Username")
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        password.placeholderString = L10n.string("Password")
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 58))
        form.addSubview(username)
        form.addSubview(password)
        alert.accessoryView = form
        alert.window.initialFirstResponder = username
        present(alert) { response in
            if response == .alertFirstButtonReturn {
                completionHandler(.useCredential, URLCredential(user: username.stringValue, password: password.stringValue, persistence: .forSession))
            } else { completionHandler(.cancelAuthenticationChallenge, nil) }
        }
    }
}

extension BrowserTab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        owner?.openPopup(configuration: configuration, after: id)
    }

    func webViewDidClose(_ webView: WKWebView) { owner?.closeTab(id) }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? L10n.string("Website")
        alert.informativeText = message
        alert.addButton(withTitle: L10n.string("OK"))
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? L10n.string("Website")
        alert.informativeText = message
        alert.addButton(withTitle: L10n.string("OK"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? L10n.string("Website")
        alert.informativeText = prompt
        alert.addButton(withTitle: L10n.string("OK"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        let input = NSTextField(string: defaultText ?? "")
        input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? input.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        if let window = webView.window {
            panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
        } else { completionHandler(panel.runModal() == .OK ? panel.urls : nil) }
    }
}

extension BrowserTab: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        if let window = webView.window ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.url : nil) }
        } else { completionHandler(panel.runModal() == .OK ? panel.url : nil) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled),
              !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) else { return }
        let alert = NSAlert()
        alert.messageText = L10n.string("Download failed")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.string("OK"))
        present(alert) { _ in }
    }
}
