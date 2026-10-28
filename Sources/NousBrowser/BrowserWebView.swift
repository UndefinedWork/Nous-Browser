import AppKit
import WebKit

/// Retains WebKit's native editing menu, routing website links and selection
/// searches through Nous instead of macOS's default-browser search service.
@MainActor
final class BrowserWebView: WKWebView {
    var onOpenLinkInNewTab: ((URL) -> Void)?
    var onOpenLinkInNewWindow: ((URL) -> Void)?
    var onSearchSelection: ((String) -> Void)?
    var onDownload: ((DownloadRequest) -> Void)?
    var searchEngineTitle: (() -> String)?

    static let contextMenuWorld = WKContentWorld.world(name: "NousBrowserLinkContextMenu")
    private static let handlerName = "nousLinkContextMenu"
    private static let scriptMarker = "nous-browser-link-context-menu-v1"
    private static let hubs = NSMapTable<WKUserContentController, MessageHub>(keyOptions: .weakMemory,
                                                                           valueOptions: .strongMemory)
    private var contextLink: ContextLink?
    private var contextSelection: ContextSelection?
    private var contextDownloads: ContextDownloads?
    private static let serviceMenuFilter = ServiceMenuFilter()
    private var openMenu: OpenMenu?
    private var isContextMenuActive = true
    private var urlObservation: NSKeyValueObservation?

    override init(frame: NSRect, configuration: WKWebViewConfiguration) {
        Self.configure(configuration)
        super.init(frame: frame, configuration: configuration)
        let controller = self.configuration.userContentController
        let hub: MessageHub
        if let existing = Self.hubs.object(forKey: controller) { hub = existing }
        else {
            hub = MessageHub(controller: controller)
            controller.add(hub, contentWorld: Self.contextMenuWorld, name: Self.handlerName)
            Self.hubs.setObject(hub, forKey: controller)
        }
        hub.views[ObjectIdentifier(self)] = WeakView(self)
        urlObservation = observe(\.url) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.clearContextLink() }
        }
        _ = Self.serviceMenuFilter

    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:configuration:)") }

    /// Safe for inherited popup configurations: retain their data store,
    /// preferences and controller, and install the listener only once.
    static func configure(_ configuration: WKWebViewConfiguration) {
        BrowserTextInputCompatibility.configure(configuration)
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source.contains(scriptMarker) }) else { return }
        controller.addUserScript(WKUserScript(source: contextMenuSource, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: contextMenuWorld))
    }

    /// Called when this particular WebKit instance is discarded or hibernated.
    func invalidateContextMenu() {
        isContextMenuActive = false
        BrowserImageClipboard.shared.cancel(for: self)
        clearContextLink()
        onOpenLinkInNewTab = nil
        onOpenLinkInNewWindow = nil
        onSearchSelection = nil
        onDownload = nil
        searchEngineTitle = nil
        urlObservation = nil
        let controller = configuration.userContentController
        if let hub = Self.hubs.object(forKey: controller) {
            hub.views[ObjectIdentifier(self)] = nil
            hub.prune()
        }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard isContextMenuActive else { return }
        guard let window else { return }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        Self.removeExternalBrowserItems(in: menu)
        openMenu = OpenMenu(menu: menu, pageURL: url, openedAt: Date(), screenPoint: screenPoint)
        let link = contextLink.flatMap { $0.matches(pageURL: url, screenPoint: screenPoint) ? $0.url : nil }
        let selection = contextSelection.flatMap { $0.matches(pageURL: url, screenPoint: screenPoint) ? $0.text : nil }
        let downloads = contextDownloads.flatMap { $0.matches(pageURL: url, screenPoint: screenPoint) ? $0.requests : nil } ?? [:]
        // Never leave WebKit's system search action installed, even if the
        // frame's trusted context message has not arrived yet.
        rewriteSearchItems(in: menu, selection: selection, websiteLink: link)
        rewriteDownloadItems(in: menu, requests: downloads)
        rewriteImageCopyItems(in: menu, imageURL: downloads[.image]?.url)
        if let link { rewriteLinkItems(in: menu, link: link) }
        if menu.items.contains(where: {
            (($0.target as? DownloadAction)?.request == nil && $0.target is DownloadAction) ||
            (($0.target as? ImageCopyAction)?.imageURL == nil && $0.target is ImageCopyAction)
        }) {
            requestDownloadHitTest(in: menu, event: event)
        }
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        clearContextLink()
    }

    /// Services are supplied independently by macOS and may be appended or
    /// reused after WebKit opens its menu. Remove their duplicate browser
    /// commands instead of letting a system service choose a different app.
    static func removeExternalBrowserItems(in menu: NSMenu, nativeSearchFormat: String? = nil,
                                           nativeOpenURLTitle: String? = nil,
                                           nativeReadingListTitle: String? = nil,
                                           nativeOpenTitle: String? = nil) {
        let titles = nativeServiceTitles
        let isServices = menu.title == titles.services || menu.title == "Services"
        let searchFormat = nativeSearchFormat ?? titles.search
        let openURLTitle = nativeOpenURLTitle ?? titles.openURL
        let readingListTitle = nativeReadingListTitle ?? titles.readingList
        let openTitle = nativeOpenTitle ?? titles.open
        for item in menu.items {
            let duplicateSearch = matchesSearchTitle(item.title, format: searchFormat) || matchesSearchTitle(item.title, format: "Search with %@")
            // Finder's generic Open service accepts NSURL and text as well as
            // filenames, so it can also hand a website to another browser.
            let browserService = isServices && (duplicateSearch || [openTitle, "Open", openURLTitle, "Open URL", readingListTitle, "Add to Reading List"].contains(item.title))
            if browserService || item.title.caseInsensitiveCompare(titles.safariViewer) == .orderedSame || item.title == "Open in Safari" {
                menu.removeItem(item)
            } else if let submenu = item.submenu {
                removeExternalBrowserItems(in: submenu, nativeSearchFormat: searchFormat,
                                           nativeOpenURLTitle: openURLTitle, nativeReadingListTitle: readingListTitle,
                                           nativeOpenTitle: openTitle)
            }
        }
    }

    private static let nativeServiceTitles: (services: String, search: String, openURL: String, readingList: String, safariViewer: String, open: String) = {
        let webCore = Bundle(identifier: "com.apple.WebCore")
        let appKit = Bundle(identifier: "com.apple.AppKit")
        let systemUI = Bundle(path: "/System/Library/CoreServices/SystemUIServer.app")
        let finder = Bundle(path: "/System/Library/CoreServices/Finder.app")
        let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari").flatMap { Bundle(url: $0) }
        let openWith = webCore?.localizedString(forKey: "Open with %@", value: "Open with %@", table: nil) ?? "Open with %@"
        return (
            appKit?.localizedString(forKey: "Services", value: "Services", table: nil) ?? "Services",
            webCore?.localizedString(forKey: "Search with %@", value: "Search with %@", table: nil) ?? "Search with %@",
            systemUI?.localizedString(forKey: "Open URL", value: "Open URL", table: "ServicesMenu") ?? "Open URL",
            safari?.localizedString(forKey: "Add to Reading List", value: "Add to Reading List", table: "ServicesMenu") ?? "Add to Reading List",
            openWith.replacingOccurrences(of: "%[tt]@", with: "%@").replacingOccurrences(of: "%@", with: "Safari"),
            (finder?.localizedString(forKey: "Finder/Open", value: "Finder/Open", table: "ServicesMenu") ?? "Finder/Open")
                .components(separatedBy: "/").last ?? "Open"
        )
    }()

    @MainActor private final class ServiceMenuFilter: NSObject {
        private var isFiltering = false
        override init() {
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(menuDidUpdate(_:)),
                                                   name: NSMenu.didAddItemNotification, object: nil)
            // The application menu can exist before the first WKWebView.
            if let menu = NSApp?.mainMenu { BrowserWebView.removeExternalBrowserItems(in: menu) }
            if let menu = NSApp?.servicesMenu { BrowserWebView.removeExternalBrowserItems(in: menu) }
        }
        @objc private func menuDidUpdate(_ notification: Notification) {
            guard !isFiltering, let menu = notification.object as? NSMenu else { return }
            isFiltering = true
            defer { isFiltering = false }
            BrowserWebView.removeExternalBrowserItems(in: menu)
        }
    }

    private func clearContextLink() {
        contextLink = nil
        contextSelection = nil
        contextDownloads = nil
        openMenu = nil
    }

    private func receive(_ message: WKScriptMessage) {
        guard isContextMenuActive, message.webView === self else { return }
        let origin = message.frameInfo.securityOrigin
        guard let body = message.body as? [String: Any],
              Self.validDocument(body["documentURL"] as? String, frameScheme: origin.protocol,
                                 frameHost: origin.host, framePort: origin.port),
              let screenX = body["screenX"] as? Double, screenX.isFinite,
              let screenY = body["screenY"] as? Double, screenY.isFinite,
              let timestamp = body["timestamp"] as? Double, timestamp.isFinite,
              let desktopTop = NSScreen.screens.first?.frame.maxY else {
            clearContextLink()
            return
        }
        let eventDate = Date(timeIntervalSince1970: timestamp / 1_000)
        let point = NSPoint(x: screenX, y: desktopTop - screenY)
        let link = Self.linkURL(from: body, frameScheme: origin.protocol, frameHost: origin.host, framePort: origin.port)
        let selection = Self.selectionText(from: body, frameScheme: origin.protocol,
                                           frameHost: origin.host, framePort: origin.port)
        contextLink = link.map { ContextLink(url: $0, pageURL: url, eventDate: eventDate, screenPoint: point) }
        let context = ContextSelection(text: selection, pageURL: url, eventDate: eventDate, screenPoint: point)
        contextSelection = context
        let downloads = Self.downloadRequests(from: body, frameScheme: origin.protocol,
                                              frameHost: origin.host, framePort: origin.port)
        contextDownloads = ContextDownloads(requests: downloads, context: context)
        // Usually the earlier mousedown/contextmenu message arrives before
        // AppKit opens the menu. If IPC is slightly later, update this same
        // menu only during its initial opening, never a subsequent menu.
        if let openMenu, context.matches(pageURL: openMenu.pageURL, screenPoint: openMenu.screenPoint),
           Date().timeIntervalSince(openMenu.openedAt) < 0.35,
           let menu = openMenu.menu {
                if let link { rewriteLinkItems(in: menu, link: link) }
            rewriteSearchItems(in: menu, selection: selection, websiteLink: link)
            rewriteDownloadItems(in: menu, requests: downloads.merging(openMenu.hitTestDownloads) { captured, _ in captured })
            rewriteImageCopyItems(in: menu, imageURL: downloads[.image]?.url ?? openMenu.hitTestDownloads[.image]?.url)
        }
    }

    /// Native media controls can consume DOM mouse/context-menu events. Query
    /// the actual native click point in our isolated world, without depending
    /// on event IPC timing or loosening its origin/coordinate checks.
    private func requestDownloadHitTest(in menu: NSMenu, event: NSEvent) {
        guard let opened = openMenu, let pageURL = url,
              let origin = URLComponents(url: pageURL, resolvingAgainstBaseURL: false),
              let scheme = origin.scheme, ["http", "https"].contains(scheme.lowercased()),
              let host = origin.host, bounds.width > 0, bounds.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let x = (point.x - bounds.minX) / bounds.width
        let y = (isFlipped ? point.y - bounds.minY : bounds.maxY - point.y) / bounds.height
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return }
        Task { @MainActor [weak self, weak menu] in
            guard let self,
                  let body = try? await self.callAsyncJavaScript(Self.downloadHitTestSource,
                    arguments: ["x": x, "y": y], in: nil, contentWorld: Self.contextMenuWorld),
                  let menu, self.isContextMenuActive,
                  let current = self.openMenu, current.id == opened.id,
                  self.url == pageURL else { return }
            let fallback = Self.downloadRequests(from: body, frameScheme: scheme,
                                                 frameHost: host, framePort: origin.port ?? 0)
            self.openMenu?.hitTestDownloads = fallback
            let captured = self.contextDownloads.flatMap {
                $0.matches(pageURL: pageURL, screenPoint: current.screenPoint) ? $0.requests : nil
            } ?? [:]
            self.rewriteDownloadItems(in: menu, requests: captured.merging(fallback) { trusted, _ in trusted })
            self.rewriteImageCopyItems(in: menu, imageURL: captured[.image]?.url ?? fallback[.image]?.url)
        }
    }

    /// WebKit can leave the pasteboard unchanged for SVG images. Keep its
    /// original action intact, then recover the actual clicked resource only
    /// if it did not write anything. Ordinary Copy and Copy Link are untouched.
    func rewriteImageCopyItems(in menu: NSMenu, imageURL: URL?, nativeTitle: String? = nil,
                              pasteboard: NSPasteboard = .general) {
        let title = nativeTitle ?? Bundle(identifier: "com.apple.WebCore")?
            .localizedString(forKey: "Copy Image", value: "Copy Image", table: nil) ?? "Copy Image"
        for item in menu.items where item.submenu == nil {
            if let existing = item.target as? ImageCopyAction,
               item.representedObject as? ImageCopyAction === existing {
                existing.imageURL = imageURL
                continue
            }
            guard item.identifier?.rawValue == "WKMenuItemIdentifierCopyImage" ||
                    item.title == title || item.title == "Copy Image",
                  item.action != nil else { continue }
            let pageURL = url
            let action = ImageCopyAction(item: item, imageURL: imageURL, pasteboard: pasteboard,
                isValid: { [weak self] in self?.isContextMenuActive == true && self?.url == pageURL },
                recover: { [weak self] imageURL, expectedCount, attempt in
                    guard let self else { return }
                    BrowserImageClipboard.shared.copyImage(from: imageURL, in: self, pasteboard: pasteboard,
                        expectedChangeCount: expectedCount,
                        isValid: { [weak self] in
                            self?.isContextMenuActive == true && self?.url == pageURL &&
                                ImageCopyAction.isCurrent(attempt, on: pasteboard)
                        }) {
                            [weak self] result in
                            guard case .failure = result, pasteboard.changeCount == expectedCount,
                                  ImageCopyAction.isCurrent(attempt, on: pasteboard),
                                  self?.isContextMenuActive == true, self?.url == pageURL,
                                  let window = self?.window, window.attachedSheet == nil else { return }
                            let alert = NSAlert()
                            alert.messageText = L10n.string("Could not copy image")
                            alert.informativeText = L10n.string("Try downloading the image and opening it again.")
                            alert.addButton(withTitle: L10n.string("OK"))
                            alert.beginSheetModal(for: window)
                        }
                })
            item.representedObject = action
            item.target = action
            item.action = #selector(ImageCopyAction.copyImage(_:))
        }
    }

    @MainActor final class ImageCopyAction: NSObject {
        private static var latestAttempts: [NSPasteboard.Name: UUID] = [:]
        var imageURL: URL?
        private let originalItem: NSMenuItem
        private let originalTarget: AnyObject?
        private let pasteboard: NSPasteboard
        private let isValid: () -> Bool
        private let recover: (URL, Int, UUID) -> Void

        init(item: NSMenuItem, imageURL: URL?, pasteboard: NSPasteboard,
             isValid: @escaping () -> Bool, recover: @escaping (URL, Int, UUID) -> Void) {
            originalItem = item.copy() as! NSMenuItem
            originalTarget = item.target
            self.imageURL = imageURL
            self.pasteboard = pasteboard
            self.isValid = isValid
            self.recover = recover
        }

        @objc func copyImage(_ sender: NSMenuItem) {
            guard isValid(), let selector = originalItem.action else { return }
            let attempt = UUID()
            Self.latestAttempts[pasteboard.name] = attempt
            let expectedCount = pasteboard.changeCount
            // The sender must retain WebKit's original representedObject.
            NSApp.sendAction(selector, to: originalTarget, from: originalItem)
            guard let imageURL else { return }
            Task { @MainActor [self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard isValid(), Self.isCurrent(attempt, on: pasteboard),
                      pasteboard.changeCount == expectedCount else { return }
                recover(imageURL, expectedCount, attempt)
            }
        }

        static func isCurrent(_ attempt: UUID, on pasteboard: NSPasteboard) -> Bool {
            latestAttempts[pasteboard.name] == attempt
        }
    }

    /// Only ordinary website links are routed through browser tabs/windows.
    /// WebKit retains responsibility for unsupported schemes and other items.
    static func linkURL(from body: Any, frameScheme: String, frameHost: String, framePort: Int) -> URL? {
        guard let body = body as? [String: Any],
              let href = body["href"] as? String, href.utf8.count <= 65_536,
              validDocument(body["documentURL"] as? String, frameScheme: frameScheme,
                            frameHost: frameHost, framePort: framePort),
              let components = URLComponents(string: href),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let link = components.url else { return nil }

        return link
    }

    static func selectionText(from body: Any, frameScheme: String, frameHost: String, framePort: Int) -> String? {
        guard let body = body as? [String: Any],
              validDocument(body["documentURL"] as? String, frameScheme: frameScheme,
                            frameHost: frameHost, framePort: framePort),
              let text = body["selection"] as? String, text.utf8.count <= 16_384 else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    struct DownloadRequest: Equatable {
        let url: URL
        var suggestedFilename: String? = nil
    }

    enum DownloadKind: String, CaseIterable {
        case link, image, video, audio
    }

    /// URLs are captured in the clicked frame, including currentSrc for srcset
    /// images and media sources. Never resolve relative URLs against the top page.
    static func downloadRequests(from body: Any, frameScheme: String, frameHost: String,
                                 framePort: Int) -> [DownloadKind: DownloadRequest] {
        guard let body = body as? [String: Any],
              validDocument(body["documentURL"] as? String, frameScheme: frameScheme,
                            frameHost: frameHost, framePort: framePort) else { return [:] }
        var requests: [DownloadKind: DownloadRequest] = [:]
        for kind in DownloadKind.allCases {
            let key = kind == .link ? "href" : kind.rawValue + "URL"
            guard let value = body[key] as? String,
                  let url = downloadURL(value, frameScheme: frameScheme, frameHost: frameHost, framePort: framePort) else { continue }
            var filename: String?
            if kind == .link, let raw = body["downloadFilename"] as? String, raw.utf8.count <= 1024 {
                let leaf = (raw.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
                    .components(separatedBy: .controlCharacters).joined()
                if !leaf.isEmpty, ![".", ".."].contains(leaf) { filename = leaf }
            }
            requests[kind] = DownloadRequest(url: url, suggestedFilename: filename)
        }
        return requests
    }

    private static func downloadURL(_ value: String, frameScheme: String, frameHost: String, framePort: Int) -> URL? {
        guard value.utf8.count <= 2 * 1024 * 1024, let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        switch scheme {
        case "http", "https":
            guard value.utf8.count <= 65_536, let host = components.host, !host.isEmpty else { return nil }
        case "blob":
            guard value.utf8.count <= 65_536,
                  let origin = URLComponents(string: String(value.dropFirst(5))),
                  origin.scheme?.lowercased() == frameScheme.lowercased(),
                  (origin.host ?? "").lowercased() == frameHost.lowercased(),
                  normalizedPort(origin.port ?? 0, scheme: frameScheme) == normalizedPort(framePort, scheme: frameScheme),
                  origin.user == nil, origin.password == nil else { return nil }
        case "data":
            guard value.contains(",") else { return nil }
        default: return nil
        }
        return url
    }

    /// Native context-menu downloads do not enter WKNavigationDelegate's
    /// didBecomeDownload callbacks. Route their existing menu items through the
    /// public startDownload API and the browser's destination chooser instead.
    func rewriteDownloadItems(in menu: NSMenu, requests: [DownloadKind: DownloadRequest],
                              nativeTitles: [DownloadKind: [String]]? = nil) {
        let titles = nativeTitles ?? Self.nativeDownloadTitles
        let pageURL = url
        for item in menu.items where item.submenu == nil {
            let previous = item.target as? DownloadAction
            let isOurs = previous != nil && (item.representedObject as? DownloadAction) === previous &&
                item.action == #selector(DownloadAction.download(_:))
            guard let kind = isOurs ? previous?.kind : DownloadKind.allCases.first(where: {
                (titles[$0] ?? []).contains(item.title)
            }) else { continue }
            let target = DownloadAction(kind: kind, request: requests[kind], canDownload: { [weak self] in
                self?.isContextMenuActive == true && self?.url == pageURL && self?.onDownload != nil
            }, perform: { [weak self] request in self?.onDownload?(request) })
            item.representedObject = target
            item.target = target
            item.action = #selector(DownloadAction.download(_:))
            item.isEnabled = target.validateMenuItem(item)
        }
    }

    private static let nativeDownloadTitles: [DownloadKind: [String]] = {
        let bundle = Bundle(identifier: "com.apple.WebCore")
        let keys: [DownloadKind: [String]] = [
            .link: ["Download Linked File", "Download Linked File As…", "Download Linked File As..."],
            .image: ["Download Image", "Save Image As…", "Save Image As...", "Save Image to Downloads"],
            .video: ["Download Video", "Download Video As…", "Save Video As…", "Save Video As..."],
            .audio: ["Download Audio", "Download Audio As…", "Save Audio As…", "Save Audio As..."]
        ]
        return keys.mapValues { values in
            Array(Set(values + values.map { bundle?.localizedString(forKey: $0, value: $0, table: nil) ?? $0 }))
        }
    }()

    private static func validDocument(_ document: String?, frameScheme: String, frameHost: String, framePort: Int) -> Bool {
        guard let document, let documentURL = URL(string: document) else { return false }
        // about:blank/srcdoc inherit their creator's security origin. For all
        // ordinary documents, require the DOM URL to match WebKit's frame
        // origin, including its non-default port; never use the top frame URL
        // to resolve a cross-origin iframe's relative link.
        if documentURL.scheme?.lowercased() == "about" {
            guard ["blank", "srcdoc"].contains(documentURL.path) else { return false }
        } else {
            guard let documentOrigin = URLComponents(url: documentURL, resolvingAgainstBaseURL: false),
                  documentOrigin.scheme?.lowercased() == frameScheme.lowercased(),
                  (documentOrigin.host ?? "").lowercased() == frameHost.lowercased(),
                  normalizedPort(documentOrigin.port ?? 0, scheme: frameScheme) == normalizedPort(framePort, scheme: frameScheme)
            else { return false }
        }
        return true
    }

    private static func normalizedPort(_ port: Int, scheme: String) -> Int {
        if port != 0 { return port }
        return scheme.lowercased() == "https" ? 443 : scheme.lowercased() == "http" ? 80 : 0
    }

    /// Search is a system service in WKWebView, not a navigation delegate
    /// callback. Replace its target/action, including a matching Services
    /// submenu item, while leaving unrelated editing and system actions alone.
    func rewriteSearchItems(in menu: NSMenu, selection: String?, nativeSearchFormat: String? = nil,
                            nativeWebSearchTitle: String? = nil, websiteLink: URL? = nil,
                            isServicesMenu: Bool = false) {
        let bundle = Bundle(identifier: "com.apple.WebCore")
        let format = nativeSearchFormat ?? bundle?.localizedString(forKey: "Search with %@", value: "Search with %@", table: nil) ?? "Search with %@"
        let webSearch = nativeWebSearchTitle ?? bundle?.localizedString(forKey: "Search the Web", value: "Search the Web", table: nil) ?? "Search the Web"
        let servicesTitle = Bundle(identifier: "com.apple.AppKit")?.localizedString(forKey: "Services", value: "Services", table: nil) ?? "Services"
        for item in menu.items {
            if let submenu = item.submenu {
                let services = isServicesMenu || [servicesTitle, "Services"].contains(item.title)
                rewriteSearchItems(in: submenu, selection: selection, nativeSearchFormat: format,
                                   nativeWebSearchTitle: webSearch, websiteLink: websiteLink, isServicesMenu: services)
                continue
            }
            let ours = item.target as? SearchAction
            let isOurs = ours != nil && (item.representedObject as? SearchAction) === ours &&
                item.action == #selector(SearchAction.search(_:))
            guard isOurs || Self.matchesSearchTitle(item.title, format: format) ||
                    Self.matchesSearchTitle(item.title, format: "Search with %@") ||
                    item.title.caseInsensitiveCompare(webSearch) == .orderedSame else { continue }
            let target = SearchAction(selection: selection ?? (isServicesMenu ? websiteLink?.absoluteString : nil), canSearch: { [weak self] in
                self?.isContextMenuActive == true && self?.onSearchSelection != nil
            }, perform: { [weak self] text in self?.onSearchSelection?(text) })
            item.title = L10n.format("Search with %@", searchEngineTitle?() ?? BrowserSearchEngine.google.title)
            item.representedObject = target
            item.target = target
            item.action = #selector(SearchAction.search(_:))
            item.isEnabled = target.validateMenuItem(item)
        }
    }

    static func matchesSearchTitle(_ title: String, format: String) -> Bool {
        let normalized = format.replacingOccurrences(of: "%[tt]@", with: "%@")
        let parts = normalized.components(separatedBy: "%@")
        guard parts.count == 2 else { return false }
        let pattern = "^" + NSRegularExpression.escapedPattern(for: parts[0]) + ".+" + NSRegularExpression.escapedPattern(for: parts[1]) + "$"
        return title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Titles come from the loaded framework's localization using Foundation's
    /// public Bundle API. Unknown titles/locales remain fully native; no
    /// private WebKit selector, identifier or numeric menu tag is consulted.
    func rewriteLinkItems(in menu: NSMenu, link: URL,
                          nativeOpenTitle: String? = nil, nativeWindowTitle: String? = nil) {
        let resourceBundle = Bundle(identifier: "com.apple.WebCore")
        let openTitle = nativeOpenTitle ?? resourceBundle?.localizedString(forKey: "Open Link", value: "Open Link", table: nil) ?? "Open Link"
        let windowTitle = nativeWindowTitle ?? resourceBundle?.localizedString(forKey: "Open Link in New Window", value: "Open Link in New Window", table: nil) ?? "Open Link in New Window"
        for item in menu.items {
            let previousAction = item.target as? LinkAction
            let isOurs = previousAction != nil && (item.representedObject as? LinkAction) === previousAction &&
                item.action == #selector(LinkAction.openLink(_:))
            let opensTab = isOurs ? previousAction!.opensTab : item.title == openTitle || item.title == "Open Link"
            let opensWindow = isOurs ? !previousAction!.opensTab : item.title == windowTitle || item.title == "Open Link in New Window"
            guard item.submenu == nil, opensTab || opensWindow else { continue }
            let target = LinkAction(opensTab: opensTab) { [weak self] in
                guard let self, self.isContextMenuActive else { return }
                if opensTab { self.onOpenLinkInNewTab?(link) }
                else { self.onOpenLinkInNewWindow?(link) }
            }
            if opensTab { item.title = L10n.string("Open in New Tab") }
            // representedObject owns the target for the lifetime of this menu
            // item, including AppKit's action dispatch after didCloseMenu.
            item.representedObject = target
            item.target = target
            item.action = #selector(LinkAction.openLink(_:))
        }
    }

    struct ContextLink {
        let url: URL
        let pageURL: URL?
        let eventDate: Date
        let screenPoint: NSPoint

        func matches(pageURL: URL?, screenPoint: NSPoint, now: Date = Date()) -> Bool {
            let age = now.timeIntervalSince(eventDate)
            return self.pageURL == pageURL && age >= -0.1 && age < 1.5 &&
                abs(self.screenPoint.x - screenPoint.x) <= 4 && abs(self.screenPoint.y - screenPoint.y) <= 4
        }
    }

    struct ContextSelection {
        let text: String?
        let pageURL: URL?
        let eventDate: Date
        let screenPoint: NSPoint

        func matches(pageURL: URL?, screenPoint: NSPoint, now: Date = Date()) -> Bool {
            let age = now.timeIntervalSince(eventDate)
            return self.pageURL == pageURL && age >= -0.1 && age < 1.5 &&
                abs(self.screenPoint.x - screenPoint.x) <= 4 && abs(self.screenPoint.y - screenPoint.y) <= 4
        }
    }

    private struct ContextDownloads {
        let requests: [DownloadKind: DownloadRequest]
        let context: ContextSelection
        func matches(pageURL: URL?, screenPoint: NSPoint) -> Bool {
            context.matches(pageURL: pageURL, screenPoint: screenPoint)
        }
    }

    private struct OpenMenu {
        let id = UUID()
        weak var menu: NSMenu?
        let pageURL: URL?
        let openedAt: Date
        let screenPoint: NSPoint
        var hitTestDownloads: [DownloadKind: DownloadRequest] = [:]
    }

    @MainActor private final class LinkAction: NSObject {
        let opensTab: Bool
        private let action: () -> Void
        init(opensTab: Bool, action: @escaping () -> Void) {
            self.opensTab = opensTab
            self.action = action
        }
        @objc func openLink(_ sender: NSMenuItem) { action() }
    }

    @MainActor private final class SearchAction: NSObject, NSMenuItemValidation {
        let selection: String?
        let canSearch: () -> Bool
        let perform: (String) -> Void
        init(selection: String?, canSearch: @escaping () -> Bool, perform: @escaping (String) -> Void) {
            self.selection = selection
            self.canSearch = canSearch
            self.perform = perform
        }
        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { selection != nil && canSearch() }
        @objc func search(_ sender: NSMenuItem) {
            guard let selection, canSearch() else { return }
            perform(selection)
        }
    }

    @MainActor private final class DownloadAction: NSObject, NSMenuItemValidation {
        let kind: DownloadKind
        let request: DownloadRequest?
        let canDownload: () -> Bool
        let perform: (DownloadRequest) -> Void
        init(kind: DownloadKind, request: DownloadRequest?, canDownload: @escaping () -> Bool,
             perform: @escaping (DownloadRequest) -> Void) {
            self.kind = kind
            self.request = request
            self.canDownload = canDownload
            self.perform = perform
        }
        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { request != nil && canDownload() }
        @objc func download(_ sender: NSMenuItem) {
            guard let request, canDownload() else { return }
            perform(request)
        }
    }

    @MainActor private final class WeakView {
        weak var value: BrowserWebView?
        init(_ value: BrowserWebView) { self.value = value }
    }

    @MainActor private final class MessageHub: NSObject, WKScriptMessageHandler {
        private weak var controller: WKUserContentController?
        var views: [ObjectIdentifier: WeakView] = [:]
        init(controller: WKUserContentController) { self.controller = controller }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == handlerName, let webView = message.webView else { return }
            views[ObjectIdentifier(webView)]?.value?.receive(message)
            prune()
        }

        func prune() {
            views = views.filter { $0.value.value != nil }
            if views.isEmpty, let controller {
                controller.removeScriptMessageHandler(forName: handlerName, contentWorld: contextMenuWorld)
                hubs.removeObject(forKey: controller)
            }
        }
    }

    static let contextMenuSource = #"""
    // nous-browser-link-context-menu-v1
    (() => {
        if (globalThis.__nousLinkContextMenuInstalled) return;
        globalThis.__nousLinkContextMenuInstalled = true;
        const report = event => {
            if (!event.isTrusted) return;
            const path = event.composedPath();
            // A closed native-control shadow tree can omit its media host
            // from the exposed event path. Only inspect the topmost element
            // under this same trusted event, never unrelated media on the page.
            if (Number.isFinite(event.clientX) && Number.isFinite(event.clientY)) {
                let hit = document.elementFromPoint?.(event.clientX, event.clientY);
                for (let depth = 0; hit && depth < 64; depth++) {
                    if (!path.includes(hit)) path.push(hit);
                    hit = hit.assignedSlot || hit.parentElement || hit.getRootNode?.().host;
                }
            }
            const anchor = path.find(node =>
                node instanceof Element && node.matches('a[href], area[href]'));
            let href = null;
            if (anchor) {
                try { href = new URL(anchor.getAttribute('href'), anchor.baseURI).href; } catch (_) {}
            }
            const source = selector => {
                const element = path.find(node => node instanceof Element && node.matches(selector));
                if (!element) return null;
                const value = element.currentSrc || element.src;
                if (!value || value.length > 2 * 1024 * 1024) return null;
                try { return new URL(value, element.baseURI).href; } catch (_) { return null; }
            };
            let selection = window.getSelection()?.toString() || '';
            window.webkit?.messageHandlers?.nousLinkContextMenu?.postMessage({
                href, selection: selection.slice(0, 16384), documentURL: document.URL,
                downloadFilename: anchor?.getAttribute('download')?.slice(0, 1024) || null,
                imageURL: source('img'), videoURL: source('video'), audioURL: source('audio'),
                screenX: event.screenX, screenY: event.screenY, timestamp: Date.now()
            });
        };
        document.addEventListener('mousedown', event => {
            if (event.button === 2 || (event.button === 0 && event.ctrlKey)) report(event);
        }, true);
        document.addEventListener('contextmenu', report, true);
    })();
    """#

    /// Function body for callAsyncJavaScript. x/y are normalized native view
    /// coordinates, so CSS zoom and Retina backing scale do not change the
    /// hit point. Cross-origin frames are deliberately left to frame messages.
    static let downloadHitTestSource = #"""
    let doc = document;
    let px = x * window.innerWidth;
    let py = y * window.innerHeight;
    let element = null;
    for (let depth = 0; depth < 16; depth++) {
        element = doc.elementFromPoint(px, py);
        if (!element) return {};
        for (let shadowDepth = 0; shadowDepth < 16; shadowDepth++) {
            const child = element.shadowRoot?.elementFromPoint?.(px, py);
            if (!child || child === element) break;
            element = child;
        }
        if (!element.matches('iframe, frame')) break;
        let childDocument;
        try { childDocument = element.contentDocument; } catch (_) { return {}; }
        if (!childDocument) return {};
        const rect = element.getBoundingClientRect();
        if (!rect.width || !rect.height || !element.offsetWidth || !element.offsetHeight) return {};
        px = (px - rect.left) * element.offsetWidth / rect.width - element.clientLeft;
        py = (py - rect.top) * element.offsetHeight / rect.height - element.clientTop;
        doc = childDocument;
    }
    const path = [];
    for (let depth = 0; element && depth < 64; depth++) {
        path.push(element);
        element = element.assignedSlot || element.parentElement || element.getRootNode?.().host;
    }
    const anchor = path.find(node => node.matches?.('a[href], area[href]'));
    const source = selector => {
        const node = path.find(item => item.matches?.(selector));
        const value = node && (node.currentSrc || node.src);
        if (!value || value.length > 2 * 1024 * 1024) return null;
        try { return new URL(value, node.baseURI).href; } catch (_) { return null; }
    };
    let href = null;
    if (anchor) {
        try { href = new URL(anchor.getAttribute('href'), anchor.baseURI).href; } catch (_) {}
    }
    return { documentURL: doc.URL, href,
        downloadFilename: anchor?.getAttribute('download')?.slice(0, 1024) || null,
        imageURL: source('img'), videoURL: source('video'), audioURL: source('audio') };
    """#
}
