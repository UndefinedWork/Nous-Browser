import AppKit
import Foundation
import NousAutomation
import WebKit

/// The app side of MCP. Every page action names a tab explicitly, so another
/// window becoming key can never redirect an agent's operation.
@MainActor
final class BrowserAutomationExecutor {
    private let windows: BrowserWindowManager
    private var busyTabs = Set<UUID>()
    private var latestSnapshots: [UUID: UUID] = [:]
    private var generation = UUID()
    private static let world = WKContentWorld.world(name: "NousBrowserAutomation")

    init(windows: BrowserWindowManager) { self.windows = windows }

    func invalidateSnapshots() {
        generation = UUID()
        latestSnapshots.removeAll()
    }

    func execute(_ request: AutomationRequest) async -> AutomationResponse {
        do {
            try Task.checkCancellation()
            try AutomationToolCatalog.validate(request)
            return try await perform(request)
        } catch is CancellationError {
            return AutomationResponse(error: "The browser operation was cancelled.")
        } catch let error as AutomationFailure {
            return AutomationResponse(error: error.message)
        } catch let error as AutomationError {
            return AutomationResponse(error: error.message)
        } catch {
            return AutomationResponse(error: "The browser operation could not complete. Refresh the page snapshot and try again.")
        }
    }

    private func perform(_ request: AutomationRequest) async throws -> AutomationResponse {
        let args = request.arguments
        switch request.tool {
        case "browser_list_windows":
            return value(.object(["windows": .array(windows.windows.map(windowValue))]))
        case "browser_list_tabs":
            let contexts: [BrowserWindowContext]
            if args["window_id"] != nil { contexts = [try context(args)] }
            else { contexts = windows.windows }
            return value(.object(["tabs": .array(contexts.flatMap { context in
                context.controller.model.tabs.map { tabValue($0, in: context) }
            })]))
        case "browser_new_window":
            let url = try optionalURL(args)
            guard let context = windows.newWindow(), let tab = context.controller.model.selectedTab else {
                throw AutomationFailure("A new window could not be created.")
            }
            context.controller.dismissAddress()
            if let url { tab.load(url); context.controller.model.persistSession() }
            return value(tabValue(tab, in: context))
        case "browser_new_tab":
            let context = try context(args)
            let url = try optionalURL(args)
            let model = context.controller.model
            var insertionIndex: Int?
            if args["after_tab_id"] != nil {
                let source = try uuid(args, "after_tab_id")
                guard let index = model.tabs.firstIndex(where: { $0.id == source }) else {
                    throw AutomationFailure("after_tab_id is not in the requested window.")
                }
                insertionIndex = index + 1
            }
            model.newTab(url: url)
            guard let tab = model.selectedTab else { throw AutomationFailure("The tab could not be created.") }
            if let insertionIndex { model.moveTab(tab.id, to: insertionIndex) }
            context.controller.dismissAddress()
            windows.activate(context)
            return value(tabValue(tab, in: context))
        case "browser_select_tab":
            let (context, tab) = try target(args)
            context.controller.model.selectTab(tab.id)
            context.controller.dismissAddress()
            windows.activate(context)
            return value(tabValue(tab, in: context))
        case "browser_close_tab":
            let (context, tab) = try target(args)
            guard !busyTabs.contains(tab.id) else { throw AutomationFailure("The tab has another operation in progress. Try again after it completes.") }
            latestSnapshots[tab.id] = nil
            context.controller.model.closeTab(tab.id)
            return value(.object(["closed_tab_id": .string(tab.id.uuidString)]))
        case "browser_navigate":
            let (context, tab) = try target(args)
            guard !busyTabs.contains(tab.id) else { throw AutomationFailure("The tab has another operation in progress. Try again after it completes.") }
            let url = try url(try string(args, "url"))
            latestSnapshots[tab.id] = nil
            tab.load(url)
            context.controller.model.persistSession()
            return value(tabValue(tab, in: context))
        case "browser_back", "browser_forward", "browser_reload":
            let (context, tab) = try target(args)
            try requireWebPage(tab)
            guard !busyTabs.contains(tab.id) else { throw AutomationFailure("The tab has another operation in progress. Try again after it completes.") }
            latestSnapshots[tab.id] = nil
            tab.loadIfNeeded()
            if request.tool == "browser_back" {
                guard let item = tab.webView.backForwardList.backItem else { throw AutomationFailure("This tab has no previous page.") }
                _ = try url(item.url.absoluteString)
                tab.webView.goBack()
            } else if request.tool == "browser_forward" {
                guard let item = tab.webView.backForwardList.forwardItem else { throw AutomationFailure("This tab has no next page.") }
                _ = try url(item.url.absoluteString)
                tab.webView.goForward()
            } else {
                let bypass = try boolean(args, "bypass_cache", default: false)
                if tab.errorDescription != nil || tab.webView.url == nil {
                    guard let currentURL = tab.url else { throw AutomationFailure("This tab has no page to reload.") }
                    tab.load(try url(currentURL.absoluteString), cachePolicy: bypass ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy)
                } else if bypass { tab.webView.reloadFromOrigin() }
                else { tab.webView.reload() }
            }
            return value(tabValue(tab, in: context))
        case "browser_snapshot", "browser_click", "browser_fill", "browser_press_key", "browser_scroll", "browser_screenshot":
            let (context, tab) = try target(args)
            try requireWebPage(tab)
            guard busyTabs.insert(tab.id).inserted else { throw AutomationFailure("The tab has another operation in progress. Try again after it completes.") }
            defer { busyTabs.remove(tab.id) }
            let operationGeneration = generation
            tab.loadIfNeeded()
            let webView = tab.webView
            try await waitForPage(tab, webView: webView)
            guard generation == operationGeneration else { throw AutomationFailure("Automation access was revoked during this operation.") }
            if request.tool == "browser_screenshot" {
                let image = try await screenshot(webView)
                try requireCurrent(tab, webView: webView)
                guard generation == operationGeneration else { throw AutomationFailure("Automation access was revoked during this operation.") }
                return AutomationResponse(result: .object(["tab_id": .string(tab.id.uuidString), "mime_type": .string("image/png"), "scope": .string("visible viewport")]), imageBase64: image)
            }
            var parameters: [String: Any] = ["operation": String(request.tool.dropFirst("browser_".count))]
            if request.tool == "browser_snapshot" {
                let snapshotID = UUID()
                latestSnapshots[tab.id] = nil
                parameters["snapshotID"] = snapshotID.uuidString
            } else if request.tool == "browser_scroll" {
                parameters["x"] = try number(args, "x", default: 0, range: -10_000...10_000)
                parameters["y"] = try number(args, "y", default: 0, range: -10_000...10_000)
            } else {
                let snapshotID = try uuid(args, "snapshot_id")
                guard latestSnapshots[tab.id] == snapshotID else { throw AutomationFailure("The snapshot is stale. Request browser_snapshot again before acting.") }
                parameters["snapshotID"] = snapshotID.uuidString
                parameters["ref"] = try string(args, "ref", maximum: 32)
                if request.tool == "browser_fill" { parameters["text"] = try string(args, "text", maximum: 16_384, allowEmpty: true) }
                if request.tool == "browser_press_key" {
                    let key = try string(args, "key", maximum: 32)
                    guard Self.allowedKeys.contains(key) else { throw AutomationFailure("Unsupported key. Use one of the keys listed in the tool schema.") }
                    parameters["key"] = key
                }
            }
            let result = try await script(parameters, in: webView)
            try requireCurrent(tab, webView: webView)
            guard generation == operationGeneration else { throw AutomationFailure("Automation access was revoked during this operation.") }
            if let error = result.objectValue?["error"]?.stringValue { throw AutomationFailure(error) }
            if request.tool == "browser_snapshot", let id = result.objectValue?["snapshot_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                latestSnapshots[tab.id] = id
            }
            var fields = result.objectValue ?? [:]
            fields["tab_id"] = .string(tab.id.uuidString)
            fields["window_id"] = .string(context.session.id.uuidString)
            return value(.object(fields))
        default:
            throw AutomationFailure("Unknown browser tool: \(request.tool).")
        }
    }

    private func value(_ result: JSONValue) -> AutomationResponse { AutomationResponse(result: result) }

    private func context(_ args: [String: JSONValue]) throws -> BrowserWindowContext {
        let id = try uuid(args, "window_id")
        guard let context = windows.windows.first(where: { $0.session.id == id }) else {
            throw AutomationFailure("The window no longer exists. List windows again.")
        }
        return context
    }

    private func target(_ args: [String: JSONValue]) throws -> (BrowserWindowContext, BrowserTab) {
        let id = try uuid(args, "tab_id")
        for context in windows.windows {
            if let tab = context.controller.model.tabs.first(where: { $0.id == id }) { return (context, tab) }
        }
        throw AutomationFailure("The tab no longer exists. List tabs again.")
    }

    private func windowValue(_ context: BrowserWindowContext) -> JSONValue {
        .object(["window_id": .string(context.session.id.uuidString), "title": .string(context.window.title),
                 "active": .bool(context.session.id == windows.activeWindowID),
                 "selected_tab_id": context.controller.model.selectedTabID.map { .string($0.uuidString) } ?? .null,
                 "tab_count": .number(Double(context.controller.model.tabs.count))])
    }

    private func tabValue(_ tab: BrowserTab, in context: BrowserWindowContext) -> JSONValue {
        .object(["tab_id": .string(tab.id.uuidString), "window_id": .string(context.session.id.uuidString),
                 "title": .string(tab.displayTitle), "url": .string(redactedURL(tab.url)),
                 "selected": .bool(context.controller.model.selectedTabID == tab.id), "pinned": .bool(tab.isPinned),
                 "loading": .bool(tab.isLoading), "can_go_back": .bool(tab.canGoBack), "can_go_forward": .bool(tab.canGoForward)])
    }

    private func redactedURL(_ url: URL?) -> String {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        components.user = nil
        components.password = nil
        return components.string ?? ""
    }

    private func requireWebPage(_ tab: BrowserTab) throws {
        guard tab.hasWebContent, let candidate = tab.url else { throw AutomationFailure("This is an empty tab. Navigate to an HTTP or HTTPS page first.") }
        _ = try url(candidate.absoluteString)
    }

    private func requireCurrent(_ tab: BrowserTab, webView: WKWebView) throws {
        try Task.checkCancellation()
        guard tab.webView === webView,
              windows.windows.contains(where: { $0.controller.model.tabs.contains(where: { $0 === tab }) }) else {
            throw AutomationFailure("The tab changed or closed while the operation was running.")
        }
        guard let current = webView.url else { throw AutomationFailure("The page is not ready. Wait for navigation to finish and try again.") }
        _ = try url(current.absoluteString)
    }

    private func waitForPage(_ tab: BrowserTab, webView: WKWebView) async throws {
        for _ in 0..<100 {
            try Task.checkCancellation()
            if !webView.isLoading, webView.url != nil {
                try requireCurrent(tab, webView: webView)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AutomationFailure("The page is still loading. Wait for it to finish, then request a new snapshot.")
    }

    private func script(_ arguments: [String: Any], in webView: WKWebView) async throws -> JSONValue {
        try Task.checkCancellation()
        var arguments = arguments
        arguments["deadline"] = Date().addingTimeInterval(10).timeIntervalSince1970 * 1_000
        return try await withCheckedThrowingContinuation { continuation in
            let pending = AutomationPending<JSONValue>(continuation)
            webView.callAsyncJavaScript(Self.scriptSource, arguments: arguments, in: nil, in: Self.world) { result in
                switch result {
                case .success(let object):
                    do {
                        let data = try JSONSerialization.data(withJSONObject: object as Any, options: [.fragmentsAllowed])
                        pending.finish(.success(try JSONDecoder().decode(JSONValue.self, from: data)))
                    } catch { pending.finish(.failure(AutomationFailure("The page returned an unsupported result."))) }
                case .failure: pending.finish(.failure(AutomationFailure("The page changed or its content could not be read. Request a new snapshot.")))
                }
            }
        }
    }

    private func screenshot(_ webView: WKWebView) async throws -> String {
        try Task.checkCancellation()
        guard webView.bounds.width > 0, webView.bounds.height > 0 else {
            throw AutomationFailure("Select this tab before taking its screenshot.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let pending = AutomationPending<String>(continuation)
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = NSNumber(value: min(1_440, webView.bounds.width))
            webView.takeSnapshot(with: configuration) { image, _ in
                guard let image, let png = Self.pngData(image),
                      png.count <= 8 * 1_024 * 1_024 else {
                    pending.finish(.failure(AutomationFailure("A screenshot is unavailable. Select this tab, then try again.")))
                    return
                }
                pending.finish(.success(png.base64EncodedString()))
            }
        }
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let original = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 2_000 / Double(original.width))
        let width = max(1, Int(Double(original.width) * scale))
        let height = max(1, Int(Double(original.height) * scale))
        guard height <= 8_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])
    }

    private func optionalURL(_ args: [String: JSONValue]) throws -> URL? {
        guard args["url"] != nil else { return nil }
        return try url(string(args, "url"))
    }

    private func url(_ text: String) throws -> URL {
        guard text.utf8.count <= 8_192, let result = URL(string: text),
              let components = URLComponents(url: result, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false, components.user == nil, components.password == nil else {
            throw AutomationFailure("Only HTTP or HTTPS page URLs without embedded credentials are supported.")
        }
        return result
    }

    private func string(_ args: [String: JSONValue], _ key: String, maximum: Int = 8_192, allowEmpty: Bool = false) throws -> String {
        guard let value = args[key]?.stringValue, value.utf8.count <= maximum, allowEmpty || !value.isEmpty else {
            throw AutomationFailure("\(key) must be \(allowEmpty ? "a" : "a non-empty") string of at most \(maximum) bytes.")
        }
        return value
    }

    private func uuid(_ args: [String: JSONValue], _ key: String) throws -> UUID {
        guard let result = UUID(uuidString: try string(args, key, maximum: 36)) else {
            throw AutomationFailure("\(key) must be an ID returned by this browser.")
        }
        return result
    }

    private func number(_ args: [String: JSONValue], _ key: String, default defaultValue: Double, range: ClosedRange<Double>) throws -> Double {
        guard let raw = args[key] else { return defaultValue }
        guard let value = raw.doubleValue, value.isFinite, range.contains(value) else {
            throw AutomationFailure("\(key) must be a finite number between \(range.lowerBound) and \(range.upperBound).")
        }
        return value
    }

    private func boolean(_ args: [String: JSONValue], _ key: String, default defaultValue: Bool) throws -> Bool {
        guard let raw = args[key] else { return defaultValue }
        guard let value = raw.boolValue else { throw AutomationFailure("\(key) must be a boolean.") }
        return value
    }

    private static let allowedKeys: Set<String> = ["Enter", "Tab", "Shift+Tab", "Escape", "Backspace", "Delete", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End", "PageUp", "PageDown"]

    private static let scriptSource = #"""
    if (Date.now() > deadline) return {error:'The page operation expired before it could run. Request a new snapshot.'};
    if (window !== window.top || !['http:', 'https:'].includes(location.protocol)) {
        return {error: 'Only HTTP(S) top-level pages are supported.'};
    }
    const storageKey = '__nousAutomationSnapshot';
    const maxText = 50000;
    const maxElements = 300;
    const clean = (value, limit = 240) => String(value || '').replace(/\s+/g, ' ').trim().slice(0, limit);
    function visible(element, inViewport = false) {
        if (!(element instanceof Element) || !element.isConnected || element.closest('[hidden],[inert],[aria-hidden="true"]')) return false;
        const rect = element.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0) return false;
        if (inViewport && (rect.bottom <= 0 || rect.right <= 0 || rect.top >= innerHeight || rect.left >= innerWidth)) return false;
        for (let node = element; node; node = node.parentElement) {
            const style = getComputedStyle(node);
            if (style.display === 'none' || style.visibility !== 'visible' || Number(style.opacity) === 0 || style.contentVisibility === 'hidden') return false;
        }
        return true;
    }
    function safeURL(value) {
        try {
            const url = new URL(value, location.href);
            url.username = ''; url.password = '';
            return url.href;
        } catch { return ''; }
    }
    function labelText(node) {
        if (!node || node.matches('input,textarea,select,script,style,noscript,[hidden],[aria-hidden="true"]')) return '';
        const clone = node.cloneNode(true);
        clone.querySelectorAll('input,textarea,select,script,style,noscript,[hidden],[aria-hidden="true"]').forEach(child => child.remove());
        return clone.textContent || '';
    }
    function label(element) {
        const labelled = clean(element.getAttribute('aria-labelledby'), 500).split(' ').filter(Boolean)
            .map(id => labelText(document.getElementById(id))).join(' ');
        const labels = element.labels ? Array.from(element.labels).map(labelText).join(' ') : '';
        const text = ['INPUT', 'TEXTAREA', 'SELECT'].includes(element.tagName) ? '' : labelText(element);
        return clean(element.getAttribute('aria-label') || labelled || labels || element.getAttribute('alt') || element.getAttribute('placeholder') || text || element.getAttribute('title'));
    }
    function fingerprint(element) {
        return [element.tagName, element.getAttribute('type') || '', element.getAttribute('role') || '', label(element),
            element.getAttribute('href') || '', element.form?.action || '', element.getAttribute('formaction') || ''].join('\u001f');
    }
    function role(element) {
        return element.getAttribute('role') || ({A:'link', BUTTON:'button', SELECT:'combobox', TEXTAREA:'textbox',
            IFRAME:'frame', SUMMARY:'button', INPUT: element.type === 'checkbox' ? 'checkbox' : element.type === 'radio' ? 'radio' : 'textbox'}[element.tagName]) || 'element';
    }
    function snapshot() {
        const state = {id: snapshotID, url: location.href, document, root: document.documentElement, body: document.body, refs: new Map()};
        globalThis[storageKey] = state;
        if (!globalThis.__nousAutomationLifecycle) {
            globalThis.__nousAutomationLifecycle = true;
            window.addEventListener('pagehide', () => { globalThis[storageKey] = null; });
            window.addEventListener('pageshow', () => { globalThis[storageKey] = null; });
        }
        const elements = [];
        let candidates = 0, elementsTruncated = false;
        const selector = 'a[href],button,input:not([type="hidden"]),textarea,select,summary,iframe,[role="button"],[role="link"],[role="checkbox"],[role="radio"],[role="textbox"],[role="combobox"],[tabindex],[contenteditable="true"]';
        for (const element of document.querySelectorAll(selector)) {
            if (++candidates > 20000) { elementsTruncated = true; break; }
            if (!visible(element, true)) continue;
            if (elements.length >= maxElements) { elementsTruncated = true; break; }
            const ref = 'e' + (elements.length + 1);
            const type = element instanceof HTMLInputElement ? element.type : undefined;
            const item = {ref, role: role(element), name: label(element), tag: element.tagName.toLowerCase(),
                disabled: element.matches(':disabled') || element.getAttribute('aria-disabled') === 'true'};
            if (type) item.type = type;
            if (element instanceof HTMLAnchorElement) item.url = safeURL(element.href).slice(0, 4096);
            if (type === 'checkbox' || type === 'radio') item.checked = element.checked;
            if (type === 'password' || type === 'file') item.restricted = true;
            if (element instanceof HTMLIFrameElement) item.unsupported = 'Frame contents are not exposed. Open the frame URL as its own tab if authorized.';
            elements.push(item);
            state.refs.set(ref, {element, fingerprint: fingerprint(element)});
        }
        let text = '', visited = 0, textTruncated = false;
        if (document.body) {
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            while (walker.nextNode()) {
                if (++visited > 30000) { textTruncated = true; break; }
                const parent = walker.currentNode.parentElement;
                if (!parent || parent.closest('script,style,noscript,input,textarea,select,option') || !visible(parent)) continue;
                const part = clean(walker.currentNode.textContent, maxText);
                if (!part) continue;
                if (text.length + part.length + 1 > maxText) { text += part.slice(0, maxText - text.length); textTruncated = true; break; }
                text += (text ? '\n' : '') + part;
            }
        }
        return {snapshot_id: state.id, url: safeURL(location.href), title: clean(document.title, 1000), text, elements,
            text_truncated: textTruncated, elements_truncated: elementsTruncated,
            viewport: {width: innerWidth, height: innerHeight, scroll_x: scrollX, scroll_y: scrollY},
            scope: 'Rendered top-level page text and visible top-level controls. Input values and frame contents are excluded.'};
    }
    function target() {
        const state = globalThis[storageKey];
        if (!state || state.id !== snapshotID || state.document !== document || state.url !== location.href || state.root !== document.documentElement || state.body !== document.body) {
            return {error: 'The snapshot is stale. Request browser_snapshot again before acting.'};
        }
        const entry = state.refs.get(ref);
        if (!entry || !entry.element.isConnected || entry.element.ownerDocument !== document || entry.fingerprint !== fingerprint(entry.element)) {
            return {error: 'The element changed or disappeared. Request a new snapshot.'};
        }
        const element = entry.element;
        if (element instanceof HTMLIFrameElement) return {error: 'Controls inside frames are not supported. Open the frame URL in a tab if authorized.'};
        if (!visible(element) || element.matches(':disabled') || element.getAttribute('aria-disabled') === 'true') return {error: 'The element is hidden or disabled. Request a new snapshot.'};
        if (element instanceof HTMLInputElement && ['password', 'file'].includes(element.type)) return {error: 'Password and file fields cannot be operated through MCP.'};
        element.scrollIntoView({block:'center', inline:'nearest', behavior:'instant'});
        const rect = element.getBoundingClientRect();
        const x = Math.max(0, Math.min(innerWidth - 1, (rect.left + rect.right) / 2));
        const y = Math.max(0, Math.min(innerHeight - 1, (rect.top + rect.bottom) / 2));
        const hit = document.elementFromPoint(x, y);
        if (!hit || (hit !== element && !element.contains(hit))) return {error: 'The element is covered by another control. Dismiss the overlay and request a new snapshot.'};
        return {element};
    }
    function setText(element, value) {
        if (element instanceof HTMLInputElement) {
            if (!['text','search','email','url','tel','number'].includes(element.type) || element.readOnly) return false;
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(element, value);
        } else if (element instanceof HTMLTextAreaElement) {
            if (element.readOnly) return false;
            Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(element, value);
        } else if (element.isContentEditable) { element.textContent = value; }
        else { return false; }
        element.dispatchEvent(new InputEvent('input', {bubbles:true, inputType:'insertText', data:null}));
        element.dispatchEvent(new Event('change', {bubbles:true}));
        return true;
    }
    function click(element) {
        const anchor = element.closest('a[href]');
        if (anchor && !['http:', 'https:'].includes(new URL(anchor.href, location.href).protocol)) return {error: 'Links to local files, scripts or external applications are not supported.'};
        if (element.form) {
            const action = element.getAttribute('formaction') || element.form.action;
            if (action && !['http:', 'https:'].includes(new URL(action, location.href).protocol)) return {error: 'This form does not submit to an HTTP(S) page.'};
        }
        element.focus({preventScroll:true});
        if (typeof element.click !== 'function') return {error: 'This control does not support DOM clicking.'};
        element.click();
        return {ok:true, event:'click', note:'DOM activation was dispatched. Read a new snapshot to verify the result.'};
    }
    function press(element) {
        const shiftKey = key === 'Shift+Tab';
        const actualKey = shiftKey ? 'Tab' : key;
        element.focus({preventScroll:true});
        const proceed = element.dispatchEvent(new KeyboardEvent('keydown', {key:actualKey, shiftKey, bubbles:true, cancelable:true}));
        if (proceed) {
            if (actualKey === 'Tab') {
                const controls = Array.from(document.querySelectorAll('a[href],button,input:not([type="hidden"]),textarea,select,[tabindex],[contenteditable="true"]'))
                    .filter(item => visible(item) && !item.matches(':disabled') && item.tabIndex >= 0);
                const index = controls.indexOf(element);
                if (controls.length) controls[(index + (shiftKey ? -1 : 1) + controls.length) % controls.length].focus();
            } else if (actualKey === 'Enter') {
                if (element instanceof HTMLTextAreaElement) {
                    if (element.readOnly) return {error:'This field is read-only.'};
                    const start = element.selectionStart, end = element.selectionEnd;
                    setText(element, element.value.slice(0,start) + '\n' + element.value.slice(end));
                    element.setSelectionRange(start+1,start+1);
                } else if (element instanceof HTMLInputElement && element.form) {
                    const action = element.form.action;
                    if (!['http:', 'https:'].includes(new URL(action, location.href).protocol)) return {error:'This form does not submit to an HTTP(S) page.'};
                    element.form.requestSubmit();
                } else if (element instanceof HTMLButtonElement || element instanceof HTMLAnchorElement || element.getAttribute('role') === 'button') {
                    const result = click(element); if (result.error) return result;
                }
            } else if (['Backspace','Delete','ArrowLeft','ArrowRight','Home','End'].includes(actualKey) && (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement)) {
                if (element.selectionStart == null || element.readOnly) return {error:'This field does not support text selection with this key.'};
                let start = element.selectionStart, end = element.selectionEnd;
                if (actualKey === 'Backspace' || actualKey === 'Delete') {
                    if (start === end) { if (actualKey === 'Backspace') start = Math.max(0, start - 1); else end = Math.min(element.value.length, end + 1); }
                    setText(element, element.value.slice(0,start) + element.value.slice(end));
                } else if (actualKey === 'ArrowLeft') start = Math.max(0, start - 1);
                else if (actualKey === 'ArrowRight') start = Math.min(element.value.length, end + 1);
                else if (actualKey === 'Home') start = 0;
                else if (actualKey === 'End') start = element.value.length;
                element.setSelectionRange(start,start);
            } else if (actualKey === 'PageUp' || actualKey === 'PageDown') {
                window.scrollBy({top: innerHeight * (actualKey === 'PageUp' ? -0.85 : 0.85), behavior:'instant'});
            }
        }
        element.dispatchEvent(new KeyboardEvent('keyup', {key:actualKey, shiftKey, bubbles:true}));
        return {ok:true, event:'key', note:'DOM key events were dispatched; trusted browser gestures are not emulated. Read a new snapshot to verify the result.'};
    }
    if (operation === 'snapshot') return snapshot();
    if (operation === 'scroll') {
        window.scrollBy({left:x, top:y, behavior:'instant'});
        return {ok:true, scroll_x:scrollX, scroll_y:scrollY};
    }
    const resolved = target();
    if (resolved.error) return resolved;
    const element = resolved.element;
    if (operation === 'click') return click(element);
    if (operation === 'fill') {
        element.focus({preventScroll:true});
        if (!setText(element, text)) return {error:'This control is not an editable text field. Password, file, disabled and read-only fields are unsupported.'};
        return {ok:true, event:'fill', note:'Text was entered without submitting the form.'};
    }
    if (operation === 'press_key') return press(element);
    return {error:'Unsupported page operation.'};
    """#
}

private struct AutomationFailure: Error, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// A stalled web process must not leave an MCP call pending indefinitely.
@MainActor
private final class AutomationPending<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var timeout: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
        timeout = Task { @MainActor [self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            finish(.failure(AutomationFailure("The page operation timed out. Try reloading the tab.")))
        }
    }

    func finish(_ result: Result<Value, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(with: result)
    }
}
