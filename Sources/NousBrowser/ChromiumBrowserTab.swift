import AppKit
import Foundation
import Observation

/// Chromium page ownership, with stable tab/window IDs across session restores.
@MainActor
@Observable
final class BrowserTab: NSObject, Identifiable {
    let id: UUID
    var title: String
    var url: URL?
    var isPinned: Bool {
        didSet {
            guard oldValue != isPinned else { return }
            owner?.synchronizeChromiumLifecycleState(for: self)
        }
    }
    /// The space this tab belongs to in its window.
    var spaceID: UUID?
    var isLoading = false
    var estimatedProgress = 0.0
    var canGoBack = false
    var canGoForward = false
    private(set) var isPageFullscreen = false
    var errorDescription: String?
    var favicon: NSImage?
    var passwordCandidate: BrowserPasswordAutofill.Candidate?
    var hasWebContent: Bool
    let webView: ChromiumPageView
    private(set) var isHibernated = false

    @ObservationIgnored weak var owner: BrowserModel? {
        didSet { webView.dialogPresentationWindow = owner?.chromiumPresentationWindow }
    }
    @ObservationIgnored private var hasLoaded: Bool
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var isInNativeLifecycleTransfer = false
    #if DEBUG
    // Tests observe the actual native-setter ordering without starting CEF,
    // navigating a page, mounting a view, or exposing a release API.
    @ObservationIgnored var onNativeLifecycleUpdate: ((Bool, Bool, Bool) -> Void)?
    #endif
    @ObservationIgnored private var observation: UUID?
    @ObservationIgnored private var faviconTask: Task<Void, Never>?
    @ObservationIgnored private var faviconPageURL: URL?
    @ObservationIgnored private var faviconRequestID = UUID()
    @ObservationIgnored private var passwordAutofill: ChromiumPasswordAutofill.Attachment?

    var displayTitle: String {
        if let nativePage { return nativePage.title(fallback: title) }
        return !hasWebContent && url == nil ? L10n.string("New Tab") : title
    }
    /// Library, capture editors and other pages drawn by Nous itself.
    var nativePage: NativePage? { url.flatMap(NativePage.init(url:)) }
    var pageTitle: BrowserPageTitle { BrowserPageTitle(displayTitle) }

    init(id: UUID = UUID(), title: String? = nil, url: URL? = nil, isPinned: Bool = false,
         owner: BrowserModel?, isPopup: Bool = false) {
        self.id = id
        self.isPinned = isPinned
        self.url = url
        self.owner = owner
        self.hasLoaded = isPopup
        let native = url.flatMap(NativePage.init(url:))
        self.hasWebContent = native == nil && (isPopup || url != nil)
        self.title = native?.title(fallback: title ?? "")
            ?? (url == nil && !isPopup ? L10n.string("New Tab") : title ?? Self.fallbackTitle(for: url) ?? L10n.string("New Tab"))
        self.webView = ChromiumPageView(frame: .zero)
        super.init()
        webView.dialogPresentationWindow = owner?.chromiumPresentationWindow
        if isPopup { webView.reserveForPopup() }
        // Chromium handles scrollbar visibility natively, without observing
        // editor DOM mutations or scanning shadow roots.
        observation = webView.addEventObserver { [weak self] event, payload in self?.receive(event, payload: payload) }
        webView.popupHandler = { [weak self] newWindow, activate in
            MainActor.assumeIsolated {
                guard let self, !self.isShutDown else { return nil }
                return self.owner?.openChromiumPopup(after: self.id, newWindow: newWindow, activate: activate)
            }
        }
        passwordAutofill = ChromiumPasswordAutofill.attach(to: webView) { [weak self] candidate in
            self?.passwordCandidate = candidate
        }
        if let url, native == nil { refreshFavicon(for: url) }
    }

    func isOwned(by model: BrowserModel) -> Bool { owner === model }

    func synchronizeNativeLifecycle(activeInWindow: Bool) {
        guard !isShutDown else { return }
        let active = isInNativeLifecycleTransfer || activeInWindow
        let discardable = !isInNativeLifecycleTransfer
        webView.setTabActiveInWindow(active, pinned: isPinned, autoDiscardable: discardable)
        #if DEBUG
        onNativeLifecycleUpdate?(active, isPinned, discardable)
        #endif
    }

    func prepareForNativeLifecycleTransfer() {
        guard !isShutDown else { return }
        isInNativeLifecycleTransfer = true
        synchronizeNativeLifecycle(activeInWindow: true)
    }

    func finishNativeLifecycleTransfer() {
        guard isInNativeLifecycleTransfer else { return }
        isInNativeLifecycleTransfer = false
        owner?.synchronizeChromiumLifecycleState(for: self)
    }

    func prepareAfterTransfer() {
        // The exact same CEF browser and native view move to the new window.
        // No navigation is initiated for an already-live document.
        if !hasLoaded { loadIfNeeded() }
    }

    func loadIfNeeded(force: Bool = false) {
        guard !isShutDown, (!hasLoaded || force), let url else { return }
        load(url)
    }

    func load(_ url: URL, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) {
        guard !isShutDown else { return }
        if let page = NativePage(url: url) {
            // Native pages never reach Chromium; any previous page stays hidden.
            self.url = url
            hasLoaded = true
            hasWebContent = false
            isLoading = false
            errorDescription = nil
            cancelFaviconLoading()
            favicon = nil
            title = page.title(fallback: title)
            owner?.scheduleSave()
            return
        }
        let wasBlank = !hasWebContent && self.url == nil
        self.url = url
        hasLoaded = true
        hasWebContent = true
        errorDescription = nil
        if wasBlank { title = Self.fallbackTitle(for: url) ?? url.absoluteString }
        refreshFavicon(for: url)
        if webView.url == url, cachePolicy == .reloadIgnoringLocalCacheData {
            webView.reloadFromOrigin()
        } else {
            webView.load(URLRequest(url: url, cachePolicy: cachePolicy))
        }
        owner?.scheduleSave()
    }

    func requestClose(completion: @escaping @MainActor (Bool) -> Void) {
        webView.requestPageClose(completion: completion)
    }

    func cancelFaviconLoading() {
        faviconTask?.cancel()
        faviconTask = nil
        faviconRequestID = UUID()
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        isPageFullscreen = false
        webView.dialogPresentationWindow = nil
        cancelFaviconLoading()
        passwordAutofill?.invalidate()
        passwordAutofill = nil
        passwordCandidate = nil
        if let observation { webView.removeEventObserver(observation) }
        observation = nil
        owner = nil
        webView.shutdown()
    }

    private func receive(_ event: String, payload: [String: Any]) {
        guard !isShutDown else { return }
        switch event {
        case "state":
            let previousTitle = title
            if let text = payload["title"] as? String, !text.isEmpty { title = text }
            if let address = payload["url"] as? String, let current = URL(string: address), address != "about:blank" {
                if url != current {
                    url = current
                    refreshFavicon(for: current)
                }
            }
            isLoading = payload["isLoading"] as? Bool ?? webView.isLoading
            canGoBack = payload["canGoBack"] as? Bool ?? webView.canGoBack
            canGoForward = payload["canGoForward"] as? Bool ?? webView.canGoForward
            isPageFullscreen = payload["fullscreen"] as? Bool ?? webView.fullscreen
            if let progress = payload["progress"] as? Double { estimatedProgress = min(1, max(0, progress)) }
            if !isLoading, errorDescription == nil, previousTitle != title, let url {
                owner?.recordPageTitleChange(url, title: title)
            }
            owner?.scheduleSave()
        case "load-start":
            isHibernated = false
            hasLoaded = true
            hasWebContent = true
            isLoading = true
            estimatedProgress = 0
            errorDescription = nil
            passwordCandidate = nil
        case "progress":
            if let progress = payload["progress"] as? Double { estimatedProgress = min(1, max(0, progress)) }
        case "load-end":
            isLoading = false
            estimatedProgress = 1
            if let current = webView.url, current.absoluteString != "about:blank" { url = current }
            if let text = webView.title { title = text }
            if errorDescription == nil, let url { owner?.recordVisit(url, title: title) }
            owner?.scheduleSave()
        case "error":
            if (payload["code"] as? Int) == -3 { return } // Chromium ERR_ABORTED is a cancelled navigation.
            isLoading = false
            errorDescription = payload["message"] as? String ?? L10n.string("The webpage stopped responding. Reload to continue.")
        case "discarded":
            isHibernated = true
            isLoading = false
            passwordCandidate = nil
        case "restoring":
            isHibernated = false
            isLoading = true
            errorDescription = nil
        case "favicon":
            guard let data = payload["data"] as? Data, let pageURL = url,
                  payload["pageURL"] as? String == pageURL.absoluteString,
                  let source = (payload["url"] as? String).flatMap(URL.init(string:)),
                  let image = FaviconStore.shared.storePageImage(data, for: pageURL, sourceURL: source) else { return }
            cancelFaviconLoading()
            favicon = image
        case "open-tab":
            openNativeResource(payload, inNewWindow: false)
        case "open-window":
            openNativeResource(payload, inNewWindow: true)
        case "download-complete":
            owner?.onDownloadNotice?(L10n.string("Download complete"), false)
        case "download-error":
            owner?.onDownloadNotice?(L10n.string("Download failed"), true)
        case "search":
            if let text = payload["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let owner {
                owner.openLinkInNewTab(owner.searchEngineProvider().searchURL(query: text), after: id)
            }
        case "closed":
            owner?.chromiumTabDidClose(id)
        default: break
        }
    }

    private func openNativeResource(_ payload: [String: Any], inNewWindow: Bool) {
        let activate = payload["activate"] as? Bool ?? true
        if payload["resourceKind"] as? String == "image",
           let address = payload["url"] as? String, let url = URL(string: address) {
            owner?.openChromiumImage(url, after: id, inNewWindow: inNewWindow, activate: activate)
        } else if let url = Self.websiteURL(payload["url"]) {
            if inNewWindow { owner?.openLinkInNewWindow(url, from: id) }
            else { owner?.openLinkInNewTab(url, after: id, activate: activate) }
        }
    }

    private func refreshFavicon(for pageURL: URL) {
        cancelFaviconLoading()
        let changed = faviconPageURL != pageURL
        faviconPageURL = pageURL
        guard Self.websiteURL(pageURL.absoluteString) != nil else { favicon = nil; return }
        if changed || favicon == nil { favicon = FaviconStore.shared.cachedImage(for: pageURL) }
        let request = faviconRequestID
        faviconTask = Task { [weak self] in
            let image = await FaviconStore.shared.image(for: pageURL)
            guard !Task.isCancelled, let self, !self.isShutDown,
                  self.faviconRequestID == request, self.url == pageURL else { return }
            if let image { self.favicon = image }
        }
    }

    private static func websiteURL(_ value: Any?) -> URL? {
        guard let value = value as? String, let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    private static func fallbackTitle(for url: URL?) -> String? {
        guard let url else { return nil }
        return url.isFileURL ? url.lastPathComponent : url.host
    }
}
