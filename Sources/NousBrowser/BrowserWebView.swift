import AppKit
import WebKit

/// Keeps WebKit's native context menu, replacing only its two link-opening
/// actions. The isolated bridge supplies the link hit in the correct frame.
@MainActor
final class BrowserWebView: WKWebView {
    var onOpenLinkInNewTab: ((URL) -> Void)?
    var onOpenLinkInNewWindow: ((URL) -> Void)?

    static let contextMenuWorld = WKContentWorld.world(name: "NousBrowserLinkContextMenu")
    private static let handlerName = "nousLinkContextMenu"
    private static let scriptMarker = "nous-browser-link-context-menu-v1"
    private static let hubs = NSMapTable<WKUserContentController, MessageHub>(keyOptions: .weakMemory,
                                                                           valueOptions: .strongMemory)
    private var contextLink: ContextLink?
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:configuration:)") }

    /// Safe for inherited popup configurations: retain their data store,
    /// preferences and controller, and install the listener only once.
    static func configure(_ configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source.contains(scriptMarker) }) else { return }
        controller.addUserScript(WKUserScript(source: contextMenuSource, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: contextMenuWorld))
    }

    /// Called when this particular WebKit instance is discarded or hibernated.
    func invalidateContextMenu() {
        isContextMenuActive = false
        clearContextLink()
        onOpenLinkInNewTab = nil
        onOpenLinkInNewWindow = nil
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
        openMenu = OpenMenu(menu: menu, pageURL: url, openedAt: Date(), screenPoint: screenPoint)
        if let contextLink, contextLink.matches(pageURL: url, screenPoint: screenPoint) {
            rewriteLinkItems(in: menu, link: contextLink.url)
        }
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        clearContextLink()
    }

    private func clearContextLink() {
        contextLink = nil
        openMenu = nil
    }

    private func receive(_ message: WKScriptMessage) {
        guard isContextMenuActive, message.webView === self else { return }
        let origin = message.frameInfo.securityOrigin
        guard let body = message.body as? [String: Any],
              let link = Self.linkURL(from: body, frameScheme: origin.protocol,
                                      frameHost: origin.host, framePort: origin.port),
              let screenX = body["screenX"] as? Double, screenX.isFinite,
              let screenY = body["screenY"] as? Double, screenY.isFinite,
              let timestamp = body["timestamp"] as? Double, timestamp.isFinite,
              let desktopTop = NSScreen.screens.first?.frame.maxY else {
            contextLink = nil
            return
        }
        let context = ContextLink(url: link, pageURL: url,
                                  eventDate: Date(timeIntervalSince1970: timestamp / 1_000),
                                  screenPoint: NSPoint(x: screenX, y: desktopTop - screenY))
        contextLink = context
        // Usually the earlier mousedown/contextmenu message arrives before
        // AppKit opens the menu. If IPC is slightly later, update this same
        // menu only during its initial opening, never a subsequent menu.
        if let openMenu, context.matches(pageURL: openMenu.pageURL, screenPoint: openMenu.screenPoint),
           Date().timeIntervalSince(openMenu.openedAt) < 0.35,
           let menu = openMenu.menu {
            rewriteLinkItems(in: menu, link: link)
        }
    }

    /// Only ordinary website links are routed through browser tabs/windows.
    /// WebKit retains responsibility for unsupported schemes and other items.
    static func linkURL(from body: Any, frameScheme: String, frameHost: String, framePort: Int) -> URL? {
        guard let body = body as? [String: Any],
              let href = body["href"] as? String, href.utf8.count <= 65_536,
              let document = body["documentURL"] as? String,
              let documentURL = URL(string: document),
              let components = URLComponents(string: href),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let link = components.url else { return nil }

        // about:blank/srcdoc inherit their creator's security origin. For all
        // ordinary documents, require the DOM URL to match WebKit's frame
        // origin, including its non-default port; never use the top frame URL
        // to resolve a cross-origin iframe's relative link.
        if documentURL.scheme?.lowercased() == "about" {
            guard ["blank", "srcdoc"].contains(documentURL.path) else { return nil }
        } else {
            guard let documentOrigin = URLComponents(url: documentURL, resolvingAgainstBaseURL: false),
                  documentOrigin.scheme?.lowercased() == frameScheme.lowercased(),
                  (documentOrigin.host ?? "").lowercased() == frameHost.lowercased(),
                  normalizedPort(documentOrigin.port ?? 0, scheme: frameScheme) == normalizedPort(framePort, scheme: frameScheme)
            else { return nil }
        }
        return link
    }

    private static func normalizedPort(_ port: Int, scheme: String) -> Int {
        if port != 0 { return port }
        return scheme.lowercased() == "https" ? 443 : scheme.lowercased() == "http" ? 80 : 0
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

    private struct OpenMenu {
        weak var menu: NSMenu?
        let pageURL: URL?
        let openedAt: Date
        let screenPoint: NSPoint
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
            const anchor = event.composedPath().find(node =>
                node instanceof Element && node.matches('a[href], area[href]'));
            let href = null;
            if (anchor) {
                try { href = new URL(anchor.getAttribute('href'), anchor.baseURI).href; } catch (_) {}
            }
            window.webkit?.messageHandlers?.nousLinkContextMenu?.postMessage({
                href, documentURL: document.URL,
                screenX: event.screenX, screenY: event.screenY, timestamp: Date.now()
            });
        };
        document.addEventListener('mousedown', event => {
            if (event.button === 2 || (event.button === 0 && event.ctrlKey)) report(event);
        }, true);
        document.addEventListener('contextmenu', report, true);
    })();
    """#
}
