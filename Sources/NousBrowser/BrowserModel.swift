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
    /// Injectable so tests can age tabs without waiting.
    @ObservationIgnored var now: () -> Date = Date.init

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabID } }
    var addressDisplay: String { selectedTab?.url?.absoluteString ?? "" }
    var canRestoreClosedTab: Bool { !closedTabs.isEmpty }

    init(sessionURL: URL? = nil, restoreSession: Bool = true, loadSelectedTab: Bool = true) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nous Browser", isDirectory: true)
        self.sessionURL = sessionURL ?? directory.appendingPathComponent("session.json")
        if restoreSession,
           let data = try? Data(contentsOf: self.sessionURL),
           let session = try? JSONDecoder().decode(BrowserSession.self, from: data),
           !session.tabs.isEmpty {
            let orderedTabs = session.tabs.filter(\.isPinned) + session.tabs.filter { !$0.isPinned }
            tabs = orderedTabs.map { BrowserTab(id: $0.id, title: $0.title, url: $0.url, isPinned: $0.isPinned, owner: self) }
            selectedTabID = tabs.contains(where: { $0.id == session.selectedTabID }) ? session.selectedTabID : tabs.first?.id
            isSidebarVisible = session.isSidebarVisible
            sidebarWidth = SidebarSizing.clampedWidth(session.sidebarWidth)
        } else {
            let tab = BrowserTab(title: "Apple", url: URL(string: "https://www.apple.com"), owner: self)
            tabs = [tab]
            selectedTabID = tab.id
        }
        isRestoring = false
        if loadSelectedTab { selectedTab?.loadIfNeeded() }
    }

    func newTab(url: URL? = nil) {
        let tab = BrowserTab(url: url, owner: self)
        tabs.append(tab)
        selectedTabID = tab.id
        tab.loadIfNeeded()
        persistSession()
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
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        closedTabs.append(.init(id: tab.id, title: tab.title, url: tab.url, isPinned: tab.isPinned))
        if closedTabs.count > 20 { closedTabs.removeFirst() }
        tab.cancelFaviconLoading()
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

    func navigate(_ input: String) {
        guard let url = Self.normalizeAddress(input) else { return }
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

    /// Supports URL entry, localhost development addresses, and ordinary search queries.
    /// Active-content and file schemes cannot be entered through the address field.
    nonisolated static func normalizeAddress(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
            return url
        }
        if text.contains("://") || lower.hasPrefix("javascript:") || lower.hasPrefix("data:") || lower.hasPrefix("file:") {
            return nil
        }
        if !text.contains(where: { $0.isWhitespace }) {
            let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
            let isLocal = host == "localhost" || host.hasPrefix("localhost:") || host.hasPrefix("127.0.0.1") || host.hasPrefix("[::1]")
            if isLocal { return URL(string: "http://" + text) }
            if host.contains("."), let url = URL(string: "https://" + text), url.host != nil { return url }
        }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url
    }

    func goBack() { selectedTab?.webView.goBack() }
    func goForward() { selectedTab?.webView.goForward() }
    func reload() {
        guard let tab = selectedTab else { return }
        let failed = tab.errorDescription != nil
        tab.errorDescription = nil
        if failed || tab.webView.url == nil { tab.loadIfNeeded(force: true) }
        else { tab.webView.reload() }
    }
    func stopLoading() { selectedTab?.webView.stopLoading() }
    func toggleSidebar() { isSidebarVisible.toggle() }

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

    func persistSession() {
        guard !isRestoring else { return }
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
        guard !isRestoring else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.persistSession()
        }
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
            guard playback != .playing, tabs.contains(where: { $0 === tab }), selectedTabID != id else { continue }
            tab.hibernate()
            hibernated.append(id)
        }
        return hibernated
    }

    fileprivate func openPopup(configuration: WKWebViewConfiguration) -> WKWebView {
        let tab = BrowserTab(owner: self, configuration: configuration)
        tabs.append(tab)
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
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var pendingInteractionState: Any?
    @ObservationIgnored private var needsReloadAfterTermination = false
    @ObservationIgnored private var lastTerminationReload: Date?
    @ObservationIgnored private var faviconTask: Task<Void, Never>?
    @ObservationIgnored private var faviconPageURL: URL?
    @ObservationIgnored private var faviconOrigin: String?
    @ObservationIgnored private var faviconRequestID = UUID()
    @ObservationIgnored private var passwordAutofill: BrowserPasswordAutofill.Attachment?

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
        return WKWebView(frame: .zero, configuration: config)
    }

    private func attach(_ webView: WKWebView) {
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
                    guard let self else { return }
                    self.title = view.title.flatMap { $0.isEmpty ? nil : $0 } ?? Self.fallbackTitle(for: self.url) ?? L10n.string("New Tab")
                    self.owner?.scheduleSave()
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let url = view.url {
                        if url.absoluteString != "about:blank" { self.url = url }
                        if self.faviconPageURL != url { self.refreshFavicon(for: url) }
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
        observations.forEach { $0.invalidate() }
        observations = []
        passwordAutofill?.invalidate()
        passwordAutofill = nil
        passwordCandidate = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
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

    func load(_ url: URL) {
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
            webView.load(URLRequest(url: url))
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

    private func refreshFavicon(for pageURL: URL, candidates: [URL] = []) {
        cancelFaviconLoading()
        faviconPageURL = pageURL
        guard let origin = Self.iconOrigin(for: pageURL) else {
            faviconOrigin = nil
            favicon = nil
            return
        }
        let cached = FaviconStore.shared.cachedImage(for: pageURL)
        if origin != faviconOrigin { favicon = cached }
        else if favicon == nil { favicon = cached }
        faviconOrigin = origin
        let requestID = faviconRequestID
        faviconTask = Task { [weak self] in
            // Avoid starting work for tabs already discarded before this task ran.
            guard self != nil, !Task.isCancelled else { return }
            let image = await FaviconStore.shared.image(for: pageURL, candidates: candidates)
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

    private func discoverFavicon() {
        guard let pageURL = webView.url, Self.iconOrigin(for: pageURL) != nil,
              url == pageURL else { return }
        let requestID = faviconRequestID
        // Query the main document only. href resolves relative URLs and <base>;
        // iframe icons cannot replace the top-level page's identity.
        let script = #"""
        (() => {
            const candidates = [];
            for (const link of document.querySelectorAll('link[rel]')) {
                const rel = (link.getAttribute('rel') || '').toLowerCase().split(/\s+/);
                const icon = rel.includes('icon');
                const touch = rel.includes('apple-touch-icon') || rel.includes('apple-touch-icon-precomposed');
                if (!icon && !touch) continue;
                const href = link.href;
                if (!href || !/^(https?:|data:)/i.test(href)) continue;
                const type = (link.getAttribute('type') || '').toLowerCase();
                const sizes = (link.getAttribute('sizes') || '').toLowerCase();
                let score = icon ? 1000 : 100;
                if (type.includes('svg')) score += 120;
                else if (type.includes('png')) score += 80;
                else if (type.includes('icon')) score += 60;
                if (sizes.includes('any')) score += 100;
                for (const match of sizes.matchAll(/(\d+)x(\d+)/g)) {
                    const edge = Math.min(Number(match[1]), Number(match[2]));
                    if (edge > 0) score += Math.max(0, 90 - Math.abs(Math.log2(edge / 32)) * 15);
                }
                candidates.push({ href, score });
            }
            candidates.sort((a, b) => b.score - a.score);
            return [...new Set(candidates.map(candidate => candidate.href))].slice(0, 8);
        })();
        """#
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.url == pageURL, self.webView.url == pageURL,
                  self.faviconRequestID == requestID,
                  case .success(let value) = result, let addresses = value as? [String] else { return }
            let candidates = addresses.compactMap(URL.init(string:))
            guard !candidates.isEmpty else { return }
            self.refreshFavicon(for: pageURL, candidates: candidates)
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
        errorDescription = nil
        discoverFavicon()
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
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
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
            owner?.newTab(url: url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let isAttachment = disposition.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "attachment"
        decisionHandler(isAttachment || !navigationResponse.canShowMIMEType ? .download : .allow)
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
        owner?.openPopup(configuration: configuration)
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
