import WebKit

/// Keeps Zoom Slides' canvas key handlers from treating an IME-confirming
/// Return as a second editing command. WebKit can deliver compositionend before
/// that Return with isComposing=false, while retaining keyCode 229. The site's
/// existing Safari workaround only waits 50 ms and can expire during layout.
@MainActor
enum BrowserTextInputCompatibility {
    static let world = WKContentWorld.world(name: "NousBrowserTextInputCompatibility")
    private static let marker = "nous-browser-slides-ime-return-v1"

    static func configure(_ configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source.contains(marker) }) else { return }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: world))
    }

    static let source = #"""
    // nous-browser-slides-ime-return-v1
    (() => {
        'use strict';
        const url = new URL(location.href);
        if (url.protocol !== 'https:' || url.username || url.password ||
            (url.port && url.port !== '443') ||
            !['slides.zoom.us', 'slides.zoom.com', 'present.zoom.us'].includes(url.hostname)) return;

        let confirmingReturn = null;
        const reset = () => { confirmingReturn = null; };
        const isReturn = event => event.key === 'Enter' || event.code === 'Enter' ||
            event.code === 'NumpadEnter' || event.keyCode === 13;
        const editableTarget = event => {
            for (const node of event.composedPath()) {
                if (!(node instanceof HTMLElement)) continue;
                if (node.isContentEditable || node.tagName === 'TEXTAREA') return node;
                if (node.tagName === 'INPUT' &&
                    ['text', 'search', 'email', 'url', 'tel', 'password'].includes(node.type)) return node;
            }
            return null;
        };
        const matches = (event, target) => confirmingReturn &&
            target === confirmingReturn.target && isReturn(event) &&
            (!event.code || !confirmingReturn.code || event.code === confirmingReturn.code);

        window.addEventListener('keydown', event => {
            const target = editableTarget(event);
            if (event.repeat && matches(event, target)) {
                event.stopImmediatePropagation();
                return;
            }
            // A fresh physical key press must never inherit a missing keyup.
            reset();
            if (!target || !isReturn(event) || !(event.isComposing || event.keyCode === 229)) return;
            confirmingReturn = { target, code: event.code };
            // Do not preventDefault: WebKit/the input method still owns the
            // native text commit. Only the page's additional command is blocked.
            event.stopImmediatePropagation();
        }, true);
        window.addEventListener('keypress', event => {
            if (matches(event, editableTarget(event))) event.stopImmediatePropagation();
        }, true);
        window.addEventListener('keyup', event => {
            if (!isReturn(event)) return;
            if (matches(event, editableTarget(event))) event.stopImmediatePropagation();
            reset();
        }, true);
        window.addEventListener('blur', reset, true);
        window.addEventListener('focusout', reset, true);
        window.addEventListener('pagehide', reset, true);
    })();
    """#
}
