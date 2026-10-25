import Foundation
import WebKit

/// Page focus is inspected inside WebKit, where readonly fields and shadow DOM
/// are visible. The isolated bridge sends only a history direction to its tab.
@MainActor
enum BrowserPageNavigationShortcuts {
    static let world = WKContentWorld.world(name: "NousBrowserNavigationShortcuts")
    private static let handlerName = "nousHistoryNavigation"
    private static let marker = "nous-browser-history-shortcuts-v1"
    private static let hubs = NSMapTable<WKUserContentController, MessageHub>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    static func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source.contains(marker) }) else { return }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: world))
    }

    static func attach(to webView: WKWebView,
                       onNavigate: @escaping (BrowserNavigationShortcuts.Direction) -> Void) -> Attachment {
        let controller = webView.configuration.userContentController
        let hub: MessageHub
        if let existing = hubs.object(forKey: controller) { hub = existing }
        else {
            hub = MessageHub(controller: controller)
            controller.add(hub, contentWorld: world, name: handlerName)
            hubs.setObject(hub, forKey: controller)
        }
        let attachment = Attachment(webView: webView, hub: hub, onNavigate: onNavigate)
        hub.attachments[ObjectIdentifier(webView)] = WeakAttachment(attachment)
        return attachment
    }

    static func direction(from body: Any) -> BrowserNavigationShortcuts.Direction? {
        guard let value = body as? String else { return nil }
        switch value {
        case "back": return .back
        case "forward": return .forward
        default: return nil
        }
    }

    @MainActor final class Attachment {
        private weak var webView: WKWebView?
        private var hub: MessageHub?
        private var onNavigate: ((BrowserNavigationShortcuts.Direction) -> Void)?

        fileprivate init(webView: WKWebView, hub: MessageHub,
                         onNavigate: @escaping (BrowserNavigationShortcuts.Direction) -> Void) {
            self.webView = webView
            self.hub = hub
            self.onNavigate = onNavigate
        }

        func invalidate() {
            if let webView, let hub {
                let id = ObjectIdentifier(webView)
                if hub.attachments[id]?.value === self { hub.attachments[id] = nil }
                hub.prune()
            }
            onNavigate = nil
            hub = nil
            webView = nil
        }

        fileprivate func receive(_ message: WKScriptMessage) {
            guard let webView, message.webView === webView,
                  let direction = BrowserPageNavigationShortcuts.direction(from: message.body) else { return }
            onNavigate?(direction)
        }
    }

    @MainActor fileprivate final class WeakAttachment {
        weak var value: Attachment?
        init(_ value: Attachment) { self.value = value }
    }

    @MainActor fileprivate final class MessageHub: NSObject, WKScriptMessageHandler {
        private weak var controller: WKUserContentController?
        var attachments: [ObjectIdentifier: WeakAttachment] = [:]

        init(controller: WKUserContentController) { self.controller = controller }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == handlerName, let webView = message.webView else { return }
            attachments[ObjectIdentifier(webView)]?.value?.receive(message)
            prune()
        }

        func prune() {
            attachments = attachments.filter { $0.value.value != nil }
            if attachments.isEmpty, let controller {
                controller.removeScriptMessageHandler(forName: handlerName, contentWorld: world)
                hubs.removeObject(forKey: controller)
            }
        }
    }

    static let source = #"""
    // nous-browser-history-shortcuts-v1
    (() => {
        if (globalThis.__nousHistoryShortcutsInstalled) return;
        globalThis.__nousHistoryShortcutsInstalled = true;
        window.addEventListener('keydown', event => {
            if (!event.isTrusted || event.defaultPrevented || event.isComposing ||
                !event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
            const direction = event.key === 'ArrowLeft' ? 'back' : event.key === 'ArrowRight' ? 'forward' : null;
            if (!direction || (document.designMode || '').toLowerCase() === 'on') return;
            const path = event.composedPath();
            if (path.some(node => node instanceof Element && (
                node.matches('input, textarea, select') || node.isContentEditable ||
                node.getAttribute('role') === 'textbox' || node.getAttribute('role') === 'combobox'
            ))) return;
            // A closed shadow root hides its internal path. Leave retargeted
            // custom controls alone; native inputContext provides another guard.
            const target = event.target;
            if (target instanceof Element && target.localName.includes('-') && !target.shadowRoot) return;
            // Later page listeners can still claim the shortcut in this same
            // event dispatch. Native code checks the live focus again afterward.
            setTimeout(() => {
                if (!event.defaultPrevented) window.webkit?.messageHandlers?.nousHistoryNavigation?.postMessage(direction);
            }, 0);
        });
    })();
    """#
}
