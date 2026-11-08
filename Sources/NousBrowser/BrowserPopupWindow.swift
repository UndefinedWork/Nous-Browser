import AppKit

/// A page opened with `window.open(…, features)` — typically a sign-in or
/// payment flow. It gets a small transient window over its opener instead of
/// a full browser window: no sidebar, not saved with the session, and it goes
/// away when the page calls `window.close()` or the user closes it.
@MainActor
final class BrowserPopupWindow: NSObject, NSWindowDelegate {
    private static var open: [BrowserPopupWindow] = []

    let tab: BrowserTab
    private let window: NSWindow
    private var observation: UUID?
    private var isClosing = false

    static func make(over parent: NSWindow?) -> BrowserTab {
        let popup = BrowserPopupWindow(parent: parent)
        open.append(popup)
        return popup.tab
    }

    /// Quitting: popups hold no session state worth asking about.
    static func closeAll() { open.forEach { $0.close() } }

    private init(parent: NSWindow?) {
        tab = BrowserTab(owner: nil, isPopup: true)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 320, height: 260)
        window.title = ""
        window.titlebarSeparatorStyle = .line

        let content = NSView(frame: window.contentLayoutRect)
        content.autoresizingMask = [.width, .height]
        tab.webView.frame = content.bounds
        tab.webView.autoresizingMask = [.width, .height]
        content.addSubview(tab.webView)
        window.contentView = content
        tab.webView.dialogPresentationWindow = window
        tab.webView.popupHandler = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, !self.isClosing else { return nil }
                return BrowserPopupWindow.make(over: self.window).webView
            }
        }
        observation = tab.webView.addEventObserver { [weak self] event, _ in
            MainActor.assumeIsolated { self?.receive(event) }
        }

        if let parent, parent.isVisible {
            let frame = parent.frame
            window.setFrameOrigin(NSPoint(x: frame.midX - 250, y: frame.midY - 320 + 40))
        } else {
            window.center()
        }
        tab.synchronizeNativeLifecycle(activeInWindow: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tab.webView)
        NSApp.activate()
    }

    private func receive(_ event: String) {
        switch event {
        case "state", "load-end":
            let title = tab.webView.title ?? ""
            window.title = title.isEmpty ? (tab.webView.url?.host() ?? "") : title
            // Always show which site this is: sign-in popups are a phishing target.
            window.subtitle = tab.webView.url?.host() ?? ""
        case "closed":
            close()
        default: break
        }
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        if let observation { tab.webView.removeEventObserver(observation) }
        observation = nil
        tab.webView.popupHandler = nil
        tab.shutdown()
        window.delegate = nil
        window.close()
        Self.open.removeAll { $0 === self }
    }

    func windowWillClose(_ notification: Notification) { close() }
}
