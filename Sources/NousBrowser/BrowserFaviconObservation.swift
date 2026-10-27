import Foundation
import WebKit

/// Watches the main document's declared icons without changing the document or
/// replacing page APIs. The isolated world also renders page-owned blob/SVG
/// icons using WebKit's image decoder and the page's normal resource context.
@MainActor
enum BrowserFaviconObservation {
    static let world = WKContentWorld.world(name: "NousBrowserFavicons")
    private static let handlerName = "nousFaviconChanged"
    private static let marker = "nous-browser-favicon-observation-v1"
    private static let maximumURLBytes = 2 * 1024 * 1024
    private static let hubs = NSMapTable<WKUserContentController, MessageHub>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    struct Snapshot: Equatable {
        let pageURL: URL
        let documentID: String
        let revision: Int
        let candidates: [URL]
    }

    static func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source.contains(marker) }) else { return }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: world))
    }

    static func attach(to webView: WKWebView, onChange: @escaping (Snapshot) -> Void) -> Attachment {
        let controller = webView.configuration.userContentController
        let hub: MessageHub
        if let existing = hubs.object(forKey: controller) { hub = existing }
        else {
            hub = MessageHub(controller: controller)
            controller.add(hub, contentWorld: world, name: handlerName)
            hubs.setObject(hub, forKey: controller)
        }
        let attachment = Attachment(webView: webView, hub: hub, onChange: onChange)
        hub.attachments[ObjectIdentifier(webView)] = WeakAttachment(attachment)
        return attachment
    }

    static func snapshot(from body: Any) -> Snapshot? {
        guard let value = body as? [String: Any],
              let address = value["pageURL"] as? String, address.utf8.count <= 32_768,
              let pageURL = URL(string: address), ["http", "https"].contains(pageURL.scheme?.lowercased() ?? ""),
              pageURL.host != nil, pageURL.user == nil, pageURL.password == nil,
              let documentID = value["documentID"] as? String, !documentID.isEmpty, documentID.count <= 128,
              let revision = value["revision"] as? Int, revision > 0,
              let addresses = value["candidates"] as? [String], addresses.count <= 8,
              addresses.reduce(0, { $0 + $1.utf8.count }) <= maximumURLBytes else { return nil }
        let candidates = addresses.compactMap { address -> URL? in
            guard let url = URL(string: address), url.user == nil, url.password == nil,
                  ["http", "https", "data", "blob"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        }
        guard candidates.count == addresses.count else { return nil }
        return Snapshot(pageURL: pageURL, documentID: documentID, revision: revision, candidates: candidates)
    }

    @MainActor final class Attachment {
        private weak var webView: WKWebView?
        private var hub: MessageHub?
        private var onChange: ((Snapshot) -> Void)?
        private var latest: Snapshot?

        fileprivate init(webView: WKWebView, hub: MessageHub, onChange: @escaping (Snapshot) -> Void) {
            self.webView = webView
            self.hub = hub
            self.onChange = onChange
        }

        /// Used after URL KVO/didFinish, including a same-document pushState.
        /// Forced publication recovers notifications that preceded native URL KVO.
        func refresh() {
            webView?.evaluateJavaScript("globalThis.__nousFaviconObservation?.refresh(true);", in: nil, in: world) { _ in }
        }

        func isCurrent(_ snapshot: Snapshot) -> Bool {
            hub != nil && latest == snapshot && webView?.url == snapshot.pageURL
        }

        func rasterize(_ candidate: URL, snapshot: Snapshot) async -> Data? {
            guard !Task.isCancelled, isCurrent(snapshot), snapshot.candidates.contains(candidate),
                  let webView else { return nil }
            let value = try? await webView.callAsyncJavaScript(
                "return await globalThis.__nousFaviconObservation?.rasterize(href, documentID, revision);",
                arguments: ["href": candidate.absoluteString, "documentID": snapshot.documentID, "revision": snapshot.revision],
                in: nil, contentWorld: world)
            guard !Task.isCancelled, isCurrent(snapshot), let encoded = value as? String,
                  encoded.hasPrefix("data:image/png;base64,"), encoded.utf8.count <= maximumURLBytes,
                  let comma = encoded.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(encoded[encoded.index(after: comma)...])),
                  data.count <= maximumURLBytes else { return nil }
            return data
        }

        func invalidate() {
            if let webView, let hub {
                let id = ObjectIdentifier(webView)
                if hub.attachments[id]?.value === self { hub.attachments[id] = nil }
                hub.prune()
            }
            latest = nil
            onChange = nil
            hub = nil
            webView = nil
        }

        fileprivate func receive(_ message: WKScriptMessage) {
            guard let webView, message.webView === webView, message.frameInfo.isMainFrame,
                  let snapshot = BrowserFaviconObservation.snapshot(from: message.body),
                  webView.url == snapshot.pageURL else { return }
            if let latest, latest.documentID == snapshot.documentID, latest.revision >= snapshot.revision { return }
            latest = snapshot
            onChange?(snapshot)
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
    // nous-browser-favicon-observation-v1
    (() => {
        if (window !== window.top || globalThis.__nousFaviconObservation) return;
        const maximumURLBytes = 2 * 1024 * 1024;
        const documentID = crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`;
        let revision = 0, signature = '', candidates = [], timer = null;
        let observedHead = null, observedRoot = null;
        const mediaQueries = new Map();
        const byteLength = value => new TextEncoder().encode(value).length;
        function schedule() {
            if (timer !== null) return;
            timer = setTimeout(() => { timer = null; refresh(false); }, 40);
        }
        function collect() {
            const icons = [], activeMedia = new Set();
            let order = 0;
            for (const link of document.head?.querySelectorAll('link[rel]') || []) {
                const rel = (link.getAttribute('rel') || '').toLowerCase().split(/\s+/);
                const icon = rel.includes('icon');
                const touch = rel.includes('apple-touch-icon') || rel.includes('apple-touch-icon-precomposed');
                if (!icon && !touch) continue;
                const media = link.getAttribute('media') || '';
                if (media) {
                    activeMedia.add(media);
                    if (!mediaQueries.has(media)) {
                        const query = matchMedia(media);
                        query.addEventListener('change', schedule);
                        mediaQueries.set(media, query);
                    }
                    if (!mediaQueries.get(media).matches) continue;
                }
                let url;
                try { url = new URL(link.href); } catch { continue; }
                if (!['http:', 'https:', 'data:', 'blob:'].includes(url.protocol) || url.username || url.password) continue;
                if (url.protocol === 'data:' && !url.href.toLowerCase().startsWith('data:image/')) continue;
                if (url.protocol === 'blob:' && url.origin !== location.origin) continue;
                if (byteLength(url.href) > maximumURLBytes) continue;
                const type = (link.getAttribute('type') || '').toLowerCase().split(';')[0].trim();
                if (type && !type.startsWith('image/')) continue;
                const sizes = (link.getAttribute('sizes') || '').toLowerCase();
                // All decodable image formats are peers. Unknown size and
                // scalable icons are appropriate for a small tab icon; never
                // prefer a site's static SVG over a later document PNG/emoji.
                let sizeScore = 2;
                const dimensions = [...sizes.matchAll(/(?:^|\s)(\d+)x(\d+)(?=\s|$)/g)];
                if (dimensions.length && !sizes.split(/\s+/).includes('any')) {
                    sizeScore = dimensions.some(m => Number(m[1]) >= 16 && Number(m[2]) >= 16) ? 2 : 1;
                }
                icons.push({href: url.href, rank: (icon ? 100 : 0) + sizeScore, order: order++});
            }
            for (const [media, query] of mediaQueries) if (!activeMedia.has(media)) {
                query.removeEventListener('change', schedule);
                mediaQueries.delete(media);
            }
            icons.sort((a, b) => b.rank - a.rank || b.order - a.order);
            const result = [], seen = new Set();
            let bytes = 0;
            for (const icon of icons) {
                if (seen.has(icon.href)) continue;
                seen.add(icon.href);
                if (bytes + byteLength(icon.href) > maximumURLBytes) continue;
                bytes += byteLength(icon.href);
                result.push(icon.href);
                if (result.length === 8) break;
            }
            return result;
        }
        function refresh(force = false) {
            bindHead();
            const found = collect(), next = JSON.stringify([location.href, found]);
            if (!force && next === signature) return;
            signature = next;
            candidates = found;
            revision++;
            window.webkit?.messageHandlers?.nousFaviconChanged?.postMessage({
                pageURL: location.href, documentID, revision, candidates
            });
        }
        const relevantNode = node => node.nodeType === Node.ELEMENT_NODE &&
            (node.matches('link, base') || node.querySelector('link, base'));
        const headObserver = new MutationObserver(records => {
            if (records.some(record => record.type === 'attributes' ||
                [...record.addedNodes, ...record.removedNodes].some(relevantNode))) schedule();
        });
        const rootObserver = new MutationObserver(() => { bindHead(); schedule(); });
        function bindHead() {
            if (document.documentElement !== observedRoot) {
                observedRoot = document.documentElement;
                rootObserver.disconnect();
                if (observedRoot) rootObserver.observe(observedRoot, {childList: true});
            }
            if (document.head === observedHead) return;
            observedHead = document.head;
            headObserver.disconnect();
            if (observedHead) headObserver.observe(observedHead, {
                childList: true, subtree: true, attributes: true,
                attributeFilter: ['rel', 'href', 'type', 'sizes', 'media']
            });
        }
        async function rasterize(href, expectedDocument, expectedRevision) {
            const valid = () => expectedDocument === documentID && expectedRevision === revision &&
                candidates.includes(href) && signature === JSON.stringify([location.href, collect()]);
            if (!valid()) return null;
            return await new Promise(resolve => {
                const image = new Image();
                let finished = false;
                const finish = value => {
                    if (finished) return;
                    finished = true;
                    clearTimeout(timeout);
                    image.onload = image.onerror = null;
                    if (value === null) image.src = '';
                    resolve(value);
                };
                const timeout = setTimeout(() => finish(null), 2000);
                image.onload = () => {
                    if (!valid() || !image.naturalWidth || !image.naturalHeight) { finish(null); return; }
                    try {
                        const canvas = document.createElement('canvas');
                        canvas.width = canvas.height = 64;
                        const context = canvas.getContext('2d');
                        if (!context) { finish(null); return; }
                        const scale = Math.min(64 / image.naturalWidth, 64 / image.naturalHeight);
                        const width = image.naturalWidth * scale, height = image.naturalHeight * scale;
                        context.drawImage(image, (64 - width) / 2, (64 - height) / 2, width, height);
                        const png = canvas.toDataURL('image/png');
                        finish(valid() && byteLength(png) <= maximumURLBytes ? png : null);
                    } catch { finish(null); }
                };
                image.onerror = () => finish(null);
                try {
                    const url = new URL(href);
                    // Same-origin images use the current page's existing
                    // cookies. Cross-origin rasterization is permitted only
                    // with CORS; native icon loading remains the fallback.
                    if (['http:', 'https:'].includes(url.protocol) && url.origin !== location.origin) image.crossOrigin = 'anonymous';
                    image.src = href;
                } catch { finish(null); }
            });
        }
        globalThis.__nousFaviconObservation = {refresh, rasterize};
        const documentObserver = new MutationObserver(() => { bindHead(); schedule(); });
        documentObserver.observe(document, {childList: true});
        for (const name of ['DOMContentLoaded', 'pageshow', 'hashchange', 'popstate']) window.addEventListener(name, schedule);
        bindHead();
        schedule();
    })();
    """#
}
