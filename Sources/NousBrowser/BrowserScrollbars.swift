import WebKit

/// A visual preference applied in every frame. Content remains scrollable by
/// trackpad, wheel, keyboard, and scripts; no page layout overflow is changed.
@MainActor
enum BrowserScrollbars {
    private static let marker = "nous-browser-scrollbars-v1"

    static func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source.contains(marker) }) else { return }
        controller.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .defaultClient
        ))
    }

    private static let source = #"""
    // nous-browser-scrollbars-v1
    (() => {
        const marker = '__nous_browser_scrollbar_policy_v1__';
        if (globalThis[marker]) return;
        globalThis[marker] = true;

        const css = `
            :is(#__nous_browser_scrollbar_policy__, *) {
                scrollbar-width: none !important;
            }
            :is(#__nous_browser_scrollbar_policy__, *)::-webkit-scrollbar {
                display: none !important;
                width: 0 !important;
                height: 0 !important;
            }
        `;
        const roots = new WeakMap();
        let policySheet = null;
        try {
            policySheet = new CSSStyleSheet();
            policySheet.replaceSync(css);
        } catch (_) {}

        function ensurePolicy(root, state) {
            // Constructed stylesheets work with sites whose CSP rejects inline
            // style elements. Every root in this frame can share this sheet.
            if (policySheet && 'adoptedStyleSheets' in root) {
                try {
                    if (!root.adoptedStyleSheets.includes(policySheet)) {
                        root.adoptedStyleSheets = [...root.adoptedStyleSheets, policySheet];
                    }
                    return;
                } catch (_) {}
            }
            const host = root === document ? document.head || document.documentElement : root;
            if (!host) return;
            if (!state.style) {
                state.style = document.createElement('style');
                state.style.id = marker;
                state.style.textContent = css;
            }
            if (!root.contains(state.style)) host.appendChild(state.style);
        }

        function inspectElement(element) {
            if (element.shadowRoot && element.shadowRoot.mode === 'open') {
                observeRoot(element.shadowRoot);
            }
        }

        function discoverTree(node) {
            if (node.nodeType === Node.ELEMENT_NODE) inspectElement(node);
            if (!node.querySelectorAll) return;
            for (const element of node.querySelectorAll('*')) inspectElement(element);
        }

        function observeRoot(root) {
            const existing = roots.get(root);
            if (existing) {
                ensurePolicy(root, existing);
                return;
            }
            const state = { style: null, observer: null };
            roots.set(root, state);
            state.observer = new MutationObserver(records => {
                ensurePolicy(root, state);
                const added = new Set();
                for (const record of records) {
                    for (const node of record.addedNodes) {
                        if (node.nodeType === Node.ELEMENT_NODE && node.id !== marker) added.add(node);
                    }
                }
                // A parser/framework batch may report both a parent and child.
                // Traverse each newly added subtree only once.
                for (const node of added) {
                    let parent = node.parentElement;
                    let covered = false;
                    while (parent) {
                        if (added.has(parent)) { covered = true; break; }
                        parent = parent.parentElement;
                    }
                    if (!covered && node.isConnected) discoverTree(node);
                }
            });
            state.observer.observe(root, { childList: true, subtree: true });
            ensurePolicy(root, state);
            discoverTree(root);
        }

        observeRoot(document);
        document.addEventListener('DOMContentLoaded', () => discoverTree(document), { once: true });

        // Attaching a shadow root to an already connected host doesn't emit a
        // document mutation. Discover those roots at first interaction through
        // the event's open composed path, without changing attachShadow or any
        // page/framework prototype. These listeners never cancel input.
        const inspectInteraction = event => {
            observeRoot(document);
            for (const node of event.composedPath()) {
                if (node instanceof ShadowRoot && node.mode === 'open') observeRoot(node);
                else if (node instanceof Element) inspectElement(node);
            }
        };
        for (const event of ['pointerover', 'pointerdown', 'focusin', 'wheel', 'keydown']) {
            window.addEventListener(event, inspectInteraction, { capture: true, passive: true });
        }
    })();
    """#
}
