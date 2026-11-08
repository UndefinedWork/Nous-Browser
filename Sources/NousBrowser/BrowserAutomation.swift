import AppKit
import Foundation
import NousAutomation

/// The app side of MCP. Every page action names a tab explicitly, so another
/// window becoming key can never redirect an agent's operation.
@MainActor
final class BrowserAutomationExecutor {
    private let windows: BrowserWindowManager
    private var busyTabs = Set<UUID>()
    private var latestSnapshots: [UUID: UUID] = [:]
    private var generation = UUID()
    private static let world = "NousBrowserAutomation"

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
                guard let index = model.visibleTabs.firstIndex(where: { $0.id == source }) else {
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
            busyTabs.insert(tab.id)
            defer { busyTabs.remove(tab.id) }
            let operationGeneration = generation
            let accepted: Bool = await withCheckedContinuation { continuation in
                context.controller.model.requestTabClose(tab.id) { continuation.resume(returning: $0) }
            }
            guard generation == operationGeneration else { throw AutomationFailure("Automation access was revoked during this operation.") }
            guard accepted else { throw AutomationFailure("Closing this tab was cancelled.") }
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
            guard busyTabs.insert(tab.id).inserted else { throw AutomationFailure("The tab has another operation in progress. Try again after it completes.") }
            defer { busyTabs.remove(tab.id) }
            let operationGeneration = generation
            latestSnapshots[tab.id] = nil
            tab.loadIfNeeded()
            if request.tool == "browser_back" {
                guard let destination = try await tab.webView.navigationDestination(backwards: true) else {
                    throw AutomationFailure("This tab has no previous page.")
                }
                _ = try url(destination.absoluteString)
                try requireCurrent(tab, webView: tab.webView)
                guard generation == operationGeneration else { throw AutomationFailure("Automation access was revoked during this operation.") }
                tab.webView.goBack()
            } else if request.tool == "browser_forward" {
                guard let destination = try await tab.webView.navigationDestination(backwards: false) else {
                    throw AutomationFailure("This tab has no next page.")
                }
                _ = try url(destination.absoluteString)
                try requireCurrent(tab, webView: tab.webView)
                guard generation == operationGeneration else { throw AutomationFailure("Automation access was revoked during this operation.") }
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
        case "browser_get_layout", "browser_apply_layout", "browser_space", "browser_delete_space",
             "browser_group", "browser_close_group", "browser_tab":
            return value(try await organize(request.tool, args))
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
                 "space_id": tab.spaceID.map { .string($0.uuidString) } ?? .null,
                 "group_id": tab.spaceID.flatMap { context.controller.model.layout(for: $0).location(of: tab.id)?.groupID }
                    .map { .string($0.uuidString) } ?? .null,
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

    private func requireCurrent(_ tab: BrowserTab, webView: BrowserPageView) throws {
        try Task.checkCancellation()
        guard tab.webView === webView,
              windows.windows.contains(where: { $0.controller.model.tabs.contains(where: { $0 === tab }) }) else {
            throw AutomationFailure("The tab changed or closed while the operation was running.")
        }
        guard let current = webView.url else { throw AutomationFailure("The page is not ready. Wait for navigation to finish and try again.") }
        _ = try url(current.absoluteString)
    }

    private func waitForPage(_ tab: BrowserTab, webView: BrowserPageView) async throws {
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

    private func script(_ arguments: [String: Any], in webView: BrowserPageView) async throws -> JSONValue {
        try Task.checkCancellation()
        var arguments = arguments
        arguments["deadline"] = Date().addingTimeInterval(10).timeIntervalSince1970 * 1_000
        let object = try await webView.callAsyncJavaScript(Self.scriptSource, arguments: arguments, world: Self.world)
        let data = try JSONSerialization.data(withJSONObject: object as Any, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func screenshot(_ webView: BrowserPageView) async throws -> String {
        try Task.checkCancellation()
        guard webView.bounds.width > 0, webView.bounds.height > 0 else {
            throw AutomationFailure("Select this tab before taking its screenshot.")
        }
        let data = try await webView.captureImage()
        guard let image = NSImage(data: data), let png = Self.pngData(image), png.count <= 8 * 1_024 * 1_024 else {
            throw AutomationFailure("A screenshot is unavailable. Select this tab, then try again.")
        }
        return png.base64EncodedString()
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

// MARK: - Spaces, groups and tab organization

extension BrowserAutomationExecutor {
    fileprivate func organize(_ tool: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        switch tool {
        case "browser_get_layout":
            let contexts = args["window_id"] != nil ? [try context(args)] : windows.windows
            return .object(["windows": .array(contexts.map(layoutValue)),
                            "note": .string("Pinned items are shared by every window; ordinary tabs belong to one window.")])

        case "browser_apply_layout":
            let context = try windowOrActive(args)
            let plan = try layoutPlan(args)
            let result = context.controller.model.applyLayoutPlan(plan, activate: try boolean(args, "activate", default: true))
            context.controller.dismissAddress()
            return .object([
                "window_id": .string(context.session.id.uuidString),
                "spaces": .array(result.spaces.map { .object(["space_id": .string($0.id.uuidString), "name": .string($0.name),
                                                               "created": .bool($0.created)]) }),
                "groups": .array(result.groups.map { .object(["group_id": .string($0.id.uuidString), "name": .string($0.name),
                                                               "space_id": .string($0.spaceID.uuidString)]) }),
                "created_tabs": .number(Double(result.createdTabs)), "moved_tabs": .number(Double(result.movedTabs)),
                "unchanged_tabs": .number(Double(result.keptTabs)), "created_groups": .number(Double(result.createdGroups)),
            ])

        case "browser_space":
            let action = try string(args, "action", maximum: 16)
            switch action {
            case "create":
                let context = try windowOrActive(args)
                let name = try optionalName(args)
                let icon = try optionalIcon(args)
                let id = context.controller.model.createSpace(name: name, icon: icon)
                return spaceValue(id, in: context)
            case "update":
                let (context, id) = try existingSpace(args)
                let name = try optionalName(args)
                let icon = try optionalIcon(args)
                guard name != nil || icon != nil else { throw AutomationFailure("update needs a name or an icon.") }
                context.controller.model.spaceStore.updateSpace(id, name: name, icon: icon)
                return spaceValue(id, in: context)
            case "switch":
                let context = try windowOrActive(args)
                let id = try uuid(args, "space_id")
                guard context.controller.model.spaces.contains(where: { $0.id == id }) else {
                    throw AutomationFailure("The space no longer exists. Read the layout again.")
                }
                context.controller.model.switchSpace(to: id)
                context.controller.dismissAddress()
                windows.activate(context)
                return spaceValue(id, in: context)
            case "move":
                let (context, id) = try existingSpace(args)
                let offset = Int(try number(args, "offset", default: 0, range: -50...50))
                guard offset != 0 else { throw AutomationFailure("move needs a non-zero offset.") }
                context.controller.model.spaceStore.moveSpace(id, by: offset)
                return .object(["space_ids": .array(context.controller.model.spaces.map { .string($0.id.uuidString) })])
            default:
                throw AutomationFailure("Unsupported action.")
            }

        case "browser_delete_space":
            let (context, id) = try existingSpace(args)
            let model = context.controller.model
            guard model.spaces.count > 1 else { throw AutomationFailure("The last space cannot be deleted.") }
            model.deleteSpace(id)
            return .object(["deleted_space_id": .string(id.uuidString)])

        case "browser_group":
            let action = try string(args, "action", maximum: 16)
            if action == "create" {
                let tabIDs = try (args["tab_ids"]?.arrayValue ?? []).map { item -> UUID in
                    guard let text = item.stringValue, let id = UUID(uuidString: text) else {
                        throw AutomationFailure("tab_ids must contain IDs returned by this browser.")
                    }
                    return id
                }
                let context: BrowserWindowContext
                if let first = tabIDs.first { context = try target(["tab_id": .string(first.uuidString)]).0 }
                else { context = try windowOrActive(args) }
                let model = context.controller.model
                let spaceIDs = Set(tabIDs.compactMap { model.tab($0)?.spaceID })
                guard tabIDs.allSatisfy({ model.tab($0) != nil }) else {
                    throw AutomationFailure("Every tab in tab_ids must exist in the same window. List tabs again.")
                }
                guard spaceIDs.count <= 1 else { throw AutomationFailure("Tabs in one group must come from the same space.") }
                var space = spaceIDs.first
                if args["space_id"] != nil {
                    let requested = try uuid(args, "space_id")
                    guard model.spaces.contains(where: { $0.id == requested }) else {
                        throw AutomationFailure("The space no longer exists. Read the layout again.")
                    }
                    if let space, space != requested { throw AutomationFailure("The tabs are in a different space than space_id.") }
                    space = requested
                }
                let pinned = try boolean(args, "pinned", default: false)
                if let first = tabIDs.first, let space,
                   let section = model.layout(for: space).location(of: first)?.section, (section == .pinned) != pinned,
                   args["pinned"] != nil {
                    throw AutomationFailure("The first tab is \(section == .pinned ? "pinned" : "not pinned"); omit pinned or use matching tabs.")
                }
                guard let id = model.newGroup(containing: tabIDs, section: pinned ? .pinned : .regular,
                                              name: try optionalName(args), in: space) else {
                    throw AutomationFailure("The group could not be created.")
                }
                if let icon = try optionalIcon(args) { model.updateGroup(id, icon: icon) }
                if args["expanded"] != nil { model.updateGroup(id, isExpanded: try boolean(args, "expanded", default: true)) }
                return groupValue(id, in: context)
            }
            let (context, id) = try existingGroup(args)
            let model = context.controller.model
            let section = model.layouts.values.lazy.compactMap { $0.section(ofGroup: id) }.first
            switch action {
            case "update":
                let name = try optionalName(args)
                let icon = try optionalIcon(args)
                let expanded = args["expanded"] != nil ? try boolean(args, "expanded", default: true) : nil
                guard name != nil || icon != nil || expanded != nil else {
                    throw AutomationFailure("update needs a name, an icon or expanded.")
                }
                model.updateGroup(id, name: name, icon: icon, isExpanded: expanded)
                return groupValue(id, in: context)
            case "pin", "unpin":
                if (section == .pinned) != (action == "pin") { model.toggleGroupPinned(id) }
                return groupValue(id, in: context)
            case "ungroup":
                model.ungroup(id)
                return .object(["ungrouped_group_id": .string(id.uuidString)])
            default:
                throw AutomationFailure("Unsupported action.")
            }

        case "browser_close_group":
            let (context, id) = try existingGroup(args)
            context.controller.model.closeGroup(id)
            return .object(["closed_group_id": .string(id.uuidString)])

        case "browser_tab":
            let action = try string(args, "action", maximum: 16)
            let (context, tab) = try target(args)
            let model = context.controller.model
            guard let space = tab.spaceID else { throw AutomationFailure("This tab is not in a space.") }
            switch action {
            case "pin", "unpin":
                if tab.isPinned != (action == "pin") {
                    // A tab inside a group moves to the top level of the other section.
                    model.togglePin(tab.id)
                }
            case "move":
                let layout = model.layout(for: space)
                let target: SidebarDropTarget
                if args["group_id"] != nil {
                    let groupID = try uuid(args, "group_id")
                    guard let group = layout.group(groupID), let section = layout.section(ofGroup: groupID) else {
                        throw AutomationFailure("The group is not in this tab's space. Read the layout again.")
                    }
                    let count = group.tabIDs.filter { $0 != tab.id }.count
                    target = SidebarDropTarget(section: section, groupID: groupID,
                                               index: min(Int(try number(args, "index", default: Double(count), range: 0...10_000)), count))
                } else {
                    let current = layout.location(of: tab.id)?.section ?? .regular
                    let section: SidebarSection = args["section"] != nil
                        ? (try string(args, "section", maximum: 8) == "pinned" ? .pinned : .regular) : current
                    let count = layout.nodes(section).filter { $0 != .tab(tab.id) }.count
                    target = SidebarDropTarget(section: section, groupID: nil,
                                               index: min(Int(try number(args, "index", default: Double(count), range: 0...10_000)), count))
                }
                model.move(.tab(tab.id), to: target, in: space)
            case "move_to_space":
                let destination = try uuid(args, "space_id")
                guard model.spaces.contains(where: { $0.id == destination }) else {
                    throw AutomationFailure("The space no longer exists. Read the layout again.")
                }
                model.moveTab(tab.id, toSpace: destination)
            case "move_to_window":
                let destination = try self.context(args)
                guard destination !== context else { throw AutomationFailure("The tab is already in that window.") }
                guard windows.moveTab(tab.id, from: context.session.id, to: destination.session.id,
                                      at: destination.controller.model.tabs.count) else {
                    throw AutomationFailure("The tab could not be moved to that window.")
                }
                return tabValue(tab, in: destination)
            case "duplicate":
                model.duplicateTab(tab.id)
                guard let copy = model.selectedTab, copy.id != tab.id else { throw AutomationFailure("The tab could not be duplicated.") }
                return tabValue(copy, in: context)
            default:
                throw AutomationFailure("Unsupported action.")
            }
            return tabValue(tab, in: context)

        default:
            throw AutomationFailure("Unknown browser tool: \(tool).")
        }
    }

    // MARK: Lookups

    private func windowOrActive(_ args: [String: JSONValue]) throws -> BrowserWindowContext {
        if args["window_id"] != nil { return try context(args) }
        guard let context = windows.activeContext else { throw AutomationFailure("No browser window is open. Create one first.") }
        return context
    }

    private func existingSpace(_ args: [String: JSONValue]) throws -> (BrowserWindowContext, UUID) {
        let id = try uuid(args, "space_id")
        let context = try windowOrActive(args)
        guard context.controller.model.spaces.contains(where: { $0.id == id }) else {
            throw AutomationFailure("The space no longer exists. Read the layout again.")
        }
        return (context, id)
    }

    /// Pinned groups appear in every window; prefer the named or active one.
    private func existingGroup(_ args: [String: JSONValue]) throws -> (BrowserWindowContext, UUID) {
        let id = try uuid(args, "group_id")
        let preferred = args["window_id"] != nil ? [try context(args)] : [windows.activeContext].compactMap { $0 } + windows.windows
        for context in preferred where context.controller.model.layouts.values.contains(where: { $0.group(id) != nil }) {
            return (context, id)
        }
        throw AutomationFailure("The group no longer exists. Read the layout again.")
    }

    private func optionalName(_ args: [String: JSONValue]) throws -> String? {
        guard args["name"] != nil else { return nil }
        let name = try string(args, "name", maximum: 240).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw AutomationFailure("name must be 1 to 80 characters.") }
        return name
    }

    private func optionalIcon(_ args: [String: JSONValue]) throws -> String? {
        guard let raw = args["icon"] else { return nil }
        guard let icon = raw.stringValue else { throw AutomationFailure("icon must be a string.") }
        return try Self.validIcon(icon)
    }

    /// An SF Symbol that exists on this Mac, or a single emoji.
    fileprivate static func validIcon(_ icon: String) throws -> String {
        let trimmed = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 1, trimmed.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0xFF }) {
            return trimmed
        }
        guard trimmed.utf8.count <= 64, NSImage(systemSymbolName: trimmed, accessibilityDescription: nil) != nil else {
            throw AutomationFailure("icon must be an SF Symbol name such as \"briefcase\" or a single emoji.")
        }
        return trimmed
    }

    // MARK: Values

    private func layoutValue(_ context: BrowserWindowContext) -> JSONValue {
        let model = context.controller.model
        return .object([
            "window_id": .string(context.session.id.uuidString),
            "active": .bool(context.session.id == windows.activeWindowID),
            "active_space_id": .string(model.activeSpaceID.uuidString),
            "spaces": .array(model.spaces.map { space in
                let layout = model.layout(for: space.id)
                return .object([
                    "space_id": .string(space.id.uuidString), "name": .string(space.name), "icon": .string(space.icon),
                    "active": .bool(space.id == model.activeSpaceID),
                    "pinned": .array(layout.pinned.map { nodeValue($0, model: model) }),
                    "tabs": .array(layout.regular.map { nodeValue($0, model: model) }),
                ])
            }),
        ])
    }

    private func nodeValue(_ node: SidebarNode, model: BrowserModel) -> JSONValue {
        switch node {
        case .tab(let id):
            return layoutTabValue(id, model: model)
        case .group(let group):
            return .object(["type": .string("group"), "group_id": .string(group.id.uuidString), "name": .string(group.name),
                            "icon": .string(group.icon), "expanded": .bool(group.isExpanded),
                            "tabs": .array(group.tabIDs.map { layoutTabValue($0, model: model) })])
        }
    }

    private func layoutTabValue(_ id: UUID, model: BrowserModel) -> JSONValue {
        guard let tab = model.tab(id) else { return .object(["type": .string("tab"), "tab_id": .string(id.uuidString)]) }
        return .object(["type": .string("tab"), "tab_id": .string(id.uuidString), "title": .string(tab.displayTitle),
                        "url": .string(redactedURL(tab.url)), "selected": .bool(model.selectedTabID == id),
                        "loading": .bool(tab.isLoading)])
    }

    private func spaceValue(_ id: UUID, in context: BrowserWindowContext) -> JSONValue {
        let model = context.controller.model
        guard let space = model.spaces.first(where: { $0.id == id }) else { return .object(["space_id": .string(id.uuidString)]) }
        return .object(["space_id": .string(id.uuidString), "name": .string(space.name), "icon": .string(space.icon),
                        "window_id": .string(context.session.id.uuidString), "active": .bool(model.activeSpaceID == id)])
    }

    private func groupValue(_ id: UUID, in context: BrowserWindowContext) -> JSONValue {
        let model = context.controller.model
        for (space, layout) in model.layouts {
            guard let group = layout.group(id) else { continue }
            return .object(["group_id": .string(id.uuidString), "name": .string(group.name), "icon": .string(group.icon),
                            "expanded": .bool(group.isExpanded), "pinned": .bool(layout.section(ofGroup: id) == .pinned),
                            "space_id": .string(space.uuidString), "window_id": .string(context.session.id.uuidString),
                            "tab_ids": .array(group.tabIDs.map { .string($0.uuidString) })])
        }
        return .object(["group_id": .string(id.uuidString)])
    }

    // MARK: Plan parsing

    private func layoutPlan(_ args: [String: JSONValue]) throws -> BrowserLayoutPlan {
        guard let rawSpaces = args["spaces"]?.arrayValue, !rawSpaces.isEmpty else {
            throw AutomationFailure("spaces must list at least one space.")
        }
        guard rawSpaces.count <= BrowserLayoutPlan.maximumSpaces else {
            throw AutomationFailure("A plan can describe at most \(BrowserLayoutPlan.maximumSpaces) spaces.")
        }
        let plan = BrowserLayoutPlan(spaces: try rawSpaces.enumerated().map { index, raw in
            let path = "spaces[\(index)]"
            let fields = try object(raw, path, allowed: ["name", "icon", "pinned", "tabs"])
            return BrowserLayoutPlan.Space(name: try planName(fields["name"], "\(path).name"),
                                           icon: try fields["icon"].map { try planIcon($0, "\(path).icon") },
                                           pinned: try items(fields["pinned"], "\(path).pinned"),
                                           tabs: try items(fields["tabs"], "\(path).tabs"))
        })
        guard plan.tabCount <= BrowserLayoutPlan.maximumTabs else {
            throw AutomationFailure("A plan can open at most \(BrowserLayoutPlan.maximumTabs) tabs.")
        }
        return plan
    }

    private func items(_ raw: JSONValue?, _ path: String) throws -> [BrowserLayoutPlan.Item] {
        guard let raw else { return [] }
        guard let list = raw.arrayValue else { throw AutomationFailure("\(path) must be an array.") }
        return try list.enumerated().map { index, item in
            let itemPath = "\(path)[\(index)]"
            guard let fields = item.objectValue else { throw AutomationFailure("\(itemPath) must be an object.") }
            if fields["group"] != nil {
                let group = try object(item, itemPath, allowed: ["group", "icon", "expanded", "tabs"])
                guard let tabs = group["tabs"].map({ $0.arrayValue }) ?? [] else {
                    throw AutomationFailure("\(itemPath).tabs must be an array.")
                }
                var expanded: Bool?
                if let raw = group["expanded"] {
                    guard let value = raw.boolValue else { throw AutomationFailure("\(itemPath).expanded must be a boolean.") }
                    expanded = value
                }
                return .group(.init(name: try planName(group["group"], "\(itemPath).group"),
                                    icon: try group["icon"].map { try planIcon($0, "\(itemPath).icon") },
                                    expanded: expanded,
                                    tabs: try tabs.enumerated().map { try planTab($1, "\(itemPath).tabs[\($0)]") }))
            }
            return .tab(try planTab(item, itemPath))
        }
    }

    private func planTab(_ raw: JSONValue, _ path: String) throws -> BrowserLayoutPlan.Tab {
        let fields = try object(raw, path, allowed: ["url", "title"])
        guard let text = fields["url"]?.stringValue else { throw AutomationFailure("\(path).url is required.") }
        var title: String?
        if let raw = fields["title"] {
            guard let value = raw.stringValue, value.count <= 200 else { throw AutomationFailure("\(path).title must be a short string.") }
            title = value.isEmpty ? nil : value
        }
        do { return .init(url: try url(text), title: title) }
        catch { throw AutomationFailure("\(path).url must be an http:// or https:// address.") }
    }

    private func planName(_ raw: JSONValue?, _ path: String) throws -> String {
        guard let name = raw?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 80 else {
            throw AutomationFailure("\(path) must be a name of 1 to 80 characters.")
        }
        return name
    }

    private func planIcon(_ raw: JSONValue, _ path: String) throws -> String {
        guard let icon = raw.stringValue else { throw AutomationFailure("\(path) must be a string.") }
        do { return try Self.validIcon(icon) }
        catch { throw AutomationFailure("\(path) must be an SF Symbol name such as \"briefcase\" or a single emoji.") }
    }

    private func object(_ raw: JSONValue, _ path: String, allowed: Set<String>) throws -> [String: JSONValue] {
        guard let fields = raw.objectValue else { throw AutomationFailure("\(path) must be an object.") }
        if let unexpected = fields.keys.first(where: { !allowed.contains($0) }) {
            throw AutomationFailure("\(path) has an unexpected field: \(unexpected.prefix(64)).")
        }
        return fields
    }
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
