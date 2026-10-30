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
            const shadow = element.shadowRoot;
            if (shadow && shadow.mode === 'open') observeRoot(shadow);
        }

        const pendingTrees = new Set();
        let discoveryScheduled = false;
        let traversal = null;

        function scheduleDiscovery() {
            if (discoveryScheduled) return;
            discoveryScheduled = true;
            // Editing frameworks can move the same large subtree repeatedly
            // across mutation callbacks. Coalesce those moves before walking
            // it, and yield between bounded chunks rather than blocking input.
            if (typeof requestIdleCallback === 'function') {
                requestIdleCallback(discoverPending, { timeout: 120 });
            } else {
                setTimeout(discoverPending, 16);
            }
        }

        function enqueueTree(node) {
            pendingTrees.add(node);
            scheduleDiscovery();
        }

        function prunePendingTrees() {
            for (const node of pendingTrees) {
                if (!node.isConnected) { pendingTrees.delete(node); continue; }
                // Include Document/ShadowRoot ancestors here; TreeWalker never
                // crosses a shadow boundary, so each shadow is queued itself.
                let parent = node.parentNode;
                while (parent && !pendingTrees.has(parent)) parent = parent.parentNode;
                if (parent) pendingTrees.delete(node);
            }
        }

        function nextTraversal() {
            for (const node of pendingTrees) {
                pendingTrees.delete(node);
                if (!node.isConnected) continue;
                const walker = document.createTreeWalker(node, NodeFilter.SHOW_ELEMENT);
                return { walker, next: node.nodeType === Node.ELEMENT_NODE ? node : walker.nextNode() };
            }
            return null;
        }

        function discoverPending() {
            discoveryScheduled = false;
            const started = performance.now();
            prunePendingTrees();
            let budget = 256;
            while (budget > 0 && performance.now() - started < 3) {
                if (!traversal) traversal = nextTraversal();
                if (!traversal) break;
                const node = traversal.next;
                if (!node) { traversal = null; continue; }
                traversal.next = traversal.walker.nextNode();
                if (node.isConnected) inspectElement(node);
                budget--;
            }
            if (traversal || pendingTrees.size) scheduleDiscovery();
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
                for (const record of records) {
                    for (const node of record.addedNodes) {
                        if (node.nodeType === Node.ELEMENT_NODE && node.id !== marker) pendingTrees.add(node);
                    }
                }
                if (pendingTrees.size) scheduleDiscovery();
            });
            state.observer.observe(root, { childList: true, subtree: true });
            ensurePolicy(root, state);
            enqueueTree(root);
        }

        observeRoot(document);

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
