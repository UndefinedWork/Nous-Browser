import Foundation
import WebKit

/// Detection sends field metadata only. Credentials enter the page solely after
/// the caller has completed native account selection and device authentication.
@MainActor
enum BrowserPasswordAutofill {
    struct Origin: Hashable, Sendable {
        let scheme: String
        let host: String
        let port: Int

        init?(url: URL, allowLoopbackHTTPForTesting: Bool = false) {
            guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
                  !host.isEmpty, url.user == nil, url.password == nil else { return nil }
            let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
            guard scheme == "https" || (allowLoopbackHTTPForTesting && scheme == "http" && loopback) else { return nil }
            self.scheme = scheme
            self.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            self.port = url.port ?? (scheme == "https" ? 443 : 80)
        }

        var serialized: String {
            let hostname = host.contains(":") ? "[\(host)]" : host
            let defaultPort = scheme == "https" ? 443 : 80
            return "\(scheme)://\(hostname)" + (port == defaultPort ? "" : ":\(port)")
        }

        var url: URL { URL(string: serialized)! }
    }

    struct Candidate: Equatable, Sendable {
        let token: String
        let frameURL: URL
        let origin: Origin
        let fieldTypes: [String]
    }

    struct Values: Sendable {
        let username: String
        let password: String
    }

    struct FillResult: Equatable, Sendable {
        let didFillUsername: Bool
    }

    enum Failure: Error, Sendable {
        case invalidCredential
        case invalidOrigin
        case staleDocument
        case noCompatibleForm
        case bridgeUnavailable
    }

    private static let handlerName = "nousPasswordCandidate"
    private static let marker = "nous-browser-password-autofill-v1"
    private static let world = WKContentWorld.world(name: "NousBrowserPasswordAutofill")
    private static let hubs = NSMapTable<WKUserContentController, MessageHub>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    static func install(configuration: WKWebViewConfiguration, allowLoopbackHTTPForTesting: Bool = false) {
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source.contains(marker) }) else { return }
        controller.addUserScript(WKUserScript(source: detectionSource(allowLoopbackHTTPForTesting: testingHTTPAllowed(allowLoopbackHTTPForTesting)),
                                             injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
    }

    static func attach(to webView: WKWebView, allowLoopbackHTTPForTesting: Bool = false,
                       onCandidate: @escaping (Candidate?) -> Void) -> Attachment {
        let controller = webView.configuration.userContentController
        let hub: MessageHub
        if let existing = hubs.object(forKey: controller) { hub = existing }
        else {
            hub = MessageHub(controller: controller)
            controller.add(hub, contentWorld: world, name: handlerName)
            hubs.setObject(hub, forKey: controller)
        }
        let attachment = Attachment(webView: webView, hub: hub,
                                    allowLoopbackHTTPForTesting: testingHTTPAllowed(allowLoopbackHTTPForTesting), onCandidate: onCandidate)
        hub.attachments[ObjectIdentifier(webView)] = WeakAttachment(attachment)
        attachment.refreshCandidate()
        return attachment
    }

    static func fill(_ values: Values, in webView: WKWebView, expectedOrigin: Origin, token: String) async throws -> FillResult {
        try Task.checkCancellation()
        guard !values.password.isEmpty, !values.password.contains(where: { $0 == "\r" || $0 == "\n" }),
              values.password.utf8.count <= 65_536, values.username.utf8.count <= 16_384 else {
            throw Failure.invalidCredential
        }
        guard UUID(uuidString: token) != nil, let initialURL = webView.url, !webView.isLoading else { throw Failure.staleDocument }
        // HTTP is never enabled for production; a candidate can contain it only
        // when both script installation and attachment explicitly opt into tests.
        let allowTestHTTP = testingHTTPAllowed(expectedOrigin.scheme == "http")
        guard Origin(url: initialURL, allowLoopbackHTTPForTesting: allowTestHTTP) == expectedOrigin else { throw Failure.invalidOrigin }

        try Task.checkCancellation()
        let result: ParsedFill = await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(fillSource,
                                       arguments: ["username": values.username, "password": values.password,
                                                   "expectedOrigin": expectedOrigin.serialized, "token": token],
                                       in: nil, in: world, completionHandler: { result in
                switch result {
                case .success(let value):
                    guard let response = value as? [String: Any] else { continuation.resume(returning: .unavailable); return }
                    if response["ok"] as? Bool == true {
                        continuation.resume(returning: .filled(response["didFillUsername"] as? Bool == true))
                    } else {
                        continuation.resume(returning: response["reason"] as? String == "stale" ? .stale : .noForm)
                    }
                case .failure:
                    continuation.resume(returning: .unavailable)
                }
            })
        }
        try Task.checkCancellation()
        guard webView.url == initialURL, !webView.isLoading else { throw Failure.staleDocument }
        switch result {
        case .filled(let username): return FillResult(didFillUsername: username)
        case .stale: throw Failure.staleDocument
        case .noForm: throw Failure.noCompatibleForm
        case .unavailable: throw Failure.bridgeUnavailable
        }
    }

    private enum ParsedFill: Sendable { case filled(Bool), stale, noForm, unavailable }

    private static func testingHTTPAllowed(_ requested: Bool) -> Bool {
        #if DEBUG
        requested
        #else
        false
        #endif
    }

    @MainActor
    final class Attachment {
        private weak var webView: WKWebView?
        private var hub: MessageHub?
        private let allowLoopbackHTTPForTesting: Bool
        private var onCandidate: ((Candidate?) -> Void)?
        private var observations: [NSKeyValueObservation] = []
        private(set) var candidate: Candidate?

        fileprivate init(webView: WKWebView, hub: MessageHub, allowLoopbackHTTPForTesting: Bool,
                         onCandidate: @escaping (Candidate?) -> Void) {
            self.webView = webView
            self.hub = hub
            self.allowLoopbackHTTPForTesting = allowLoopbackHTTPForTesting
            self.onCandidate = onCandidate
            observations = [
                webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        self?.clearCandidate()
                        self?.refreshCandidate()
                    }
                },
                webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                    MainActor.assumeIsolated {
                        if view.isLoading { self?.clearCandidate() }
                        else { self?.refreshCandidate() }
                    }
                }
            ]
        }

        func invalidate() {
            observations.forEach { $0.invalidate() }
            observations.removeAll()
            clearCandidate()
            onCandidate = nil
            if let webView, let hub {
                hub.attachments[ObjectIdentifier(webView)] = nil
                hub.prune()
            }
            hub = nil
            webView = nil
        }

        /// A native navigation/BFCache handshake. This only requests metadata;
        /// no username or password is read from the document or returned.
        func refreshCandidate() {
            guard hub != nil, let webView, !webView.isLoading, let url = webView.url,
                  Origin(url: url, allowLoopbackHTTPForTesting: allowLoopbackHTTPForTesting) != nil else { return }
            webView.evaluateJavaScript(BrowserPasswordAutofill.refreshSource, in: nil,
                                       in: BrowserPasswordAutofill.world, completionHandler: nil)
        }

        private func clearCandidate() {
            guard candidate != nil else { return }
            candidate = nil
            onCandidate?(nil)
        }

        fileprivate func receive(_ message: WKScriptMessage) {
            guard let webView, message.webView === webView, message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any], Set(body.keys) == ["token", "frameURL", "fieldTypes"],
                  let token = body["token"] as? String, let urlText = body["frameURL"] as? String,
                  urlText.utf8.count <= 32_768, let frameURL = URL(string: urlText),
                  let origin = Origin(url: frameURL, allowLoopbackHTTPForTesting: allowLoopbackHTTPForTesting),
                  let currentURL = webView.url,
                  Origin(url: currentURL, allowLoopbackHTTPForTesting: allowLoopbackHTTPForTesting) == origin,
                  currentURL == frameURL, let types = body["fieldTypes"] as? [String] else { clearCandidate(); return }
            let securityOrigin = message.frameInfo.securityOrigin
            let defaultPort = origin.scheme == "https" ? 443 : 80
            guard securityOrigin.protocol.lowercased() == origin.scheme,
                  securityOrigin.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == origin.host,
                  (securityOrigin.port > 0 ? securityOrigin.port : defaultPort) == origin.port else { clearCandidate(); return }
            if token.isEmpty && types.isEmpty { clearCandidate(); return }
            guard UUID(uuidString: token) != nil, (1...2).contains(types.count), types.contains("password"),
                  types.allSatisfy({ ["password", "text", "email", "tel"].contains($0) }) else { clearCandidate(); return }
            let next = Candidate(token: token, frameURL: frameURL, origin: origin, fieldTypes: types)
            guard candidate != next else { return }
            candidate = next
            onCandidate?(next)
        }
    }

    @MainActor
    fileprivate final class WeakAttachment {
        weak var value: Attachment?
        init(_ value: Attachment) { self.value = value }
    }

    @MainActor
    fileprivate final class MessageHub: NSObject, WKScriptMessageHandler {
        weak var controller: WKUserContentController?
        var attachments: [ObjectIdentifier: WeakAttachment] = [:]

        init(controller: WKUserContentController) { self.controller = controller }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == handlerName, message.frameInfo.isMainFrame, let webView = message.webView else { return }
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

    private static let fillSource = #"""
    const bridge = globalThis.__nousBrowserPasswordAutofill;
    if (!bridge) return { ok: false, reason: 'unavailable' };
    return bridge.fill(username, password, expectedOrigin, token);
    """#

    private static let refreshSource = #"""
    globalThis.__nousBrowserPasswordAutofill?.refreshCandidate();
    true;
    """#

    private static func detectionSource(allowLoopbackHTTPForTesting: Bool) -> String {
        "const allowLoopbackHTTP = \(allowLoopbackHTTPForTesting ? "true" : "false");\n" + #"""
        // nous-browser-password-autofill-v1
        (() => {
            if (window !== window.top || globalThis.__nousBrowserPasswordAutofill) return;
            const approvedTargets = new Set(['', '_self', '_top', '_parent']);
            const prohibited = /sign[\s_-]*up|register|registration|create[\s_-]*(account|password)|new[\s_-]*password|change[\s_-]*password|reset[\s_-]*password|update[\s_-]*password|注册|註冊|创建账|建立帳|修改密码|更改密碼|重置密码|重設密碼|パスワード.*変更|新規登録|회원가입|비밀번호.*변경/i;
            const loginHint = /sign[\s_-]*in|log[\s_-]*in|登录|登入|ログイン|サインイン|로그인/i;
            let entry = null;
            let lastSent = '';
            let scheduled = false;
            const passwordInputs = new Set();
            let discoveryDirty = true;

            function secureDocument() {
                if (window !== window.top) return false;
                if (location.protocol === 'https:') return true;
                return allowLoopbackHTTP && location.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]', '::1'].includes(location.hostname);
            }
            function editableVisible(input) {
                if (!(input instanceof HTMLInputElement) || !input.isConnected || input.ownerDocument !== document || input.matches(':disabled') || input.readOnly || input.closest('[inert],[aria-hidden="true"]')) return false;
                let rect = input.getBoundingClientRect();
                if (rect.width < 8 || rect.height < 8 || rect.bottom <= 0 || rect.right <= 0 || rect.top >= innerHeight || rect.left >= innerWidth) return false;
                for (let node = input; node; node = node.parentElement) {
                    const style = getComputedStyle(node);
                    if (node.hidden || style.display === 'none' || style.visibility !== 'visible' || Number(style.opacity) < 0.05 || style.contentVisibility === 'hidden') return false;
                    if (node !== input && /(hidden|clip|scroll|auto)/.test(style.overflowX + ' ' + style.overflowY)) {
                        const parent = node.getBoundingClientRect();
                        rect = { left: Math.max(rect.left, parent.left), right: Math.min(rect.right, parent.right), top: Math.max(rect.top, parent.top), bottom: Math.min(rect.bottom, parent.bottom) };
                        if (rect.right - rect.left < 4 || rect.bottom - rect.top < 4) return false;
                    }
                }
                const x = Math.max(0, Math.min(innerWidth - 1, (rect.left + rect.right) / 2));
                const y = Math.max(0, Math.min(innerHeight - 1, (rect.top + rect.bottom) / 2));
                return document.elementFromPoint(x, y) === input;
            }
            function autocomplete(input) { return (input.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/); }
            function analyze(form) {
                if (!secureDocument() || !(form instanceof HTMLFormElement) || !form.isConnected || !approvedTargets.has((form.getAttribute('target') || '').toLowerCase())) return null;
                const controls = [...form.elements];
                if (controls.length > 200) return null;
                const inputs = controls.filter(input => input instanceof HTMLInputElement);
                const passwords = inputs.filter(input => input.type === 'password');
                if (passwords.length !== 1 || inputs.some(input => autocomplete(input).includes('new-password'))) return null;
                const passwordInput = passwords[0];
                if (!form.contains(passwordInput) || !editableVisible(passwordInput)) return null;
                let action;
                try { action = new URL(form.getAttribute('action') || location.href, document.baseURI); }
                catch (_) { return null; }
                if (action.origin !== location.origin || action.username || action.password) return null;
                let metadata = [form.id, form.getAttribute('name') || '', form.getAttribute('aria-label') || '', action.pathname].join(' ');
                for (const control of controls) {
                    if (!(control instanceof HTMLButtonElement || control instanceof HTMLInputElement)) continue;
                    if (control.hasAttribute('formaction')) {
                        try { if (new URL(control.getAttribute('formaction'), document.baseURI).origin !== location.origin) return null; }
                        catch (_) { return null; }
                    }
                    if (control.hasAttribute('formtarget') && !approvedTargets.has((control.getAttribute('formtarget') || '').toLowerCase())) return null;
                    if (control.type === 'submit') metadata += ' ' + (control.textContent || '') + ' ' + (control.getAttribute('value') || '');
                }
                if (prohibited.test(metadata) || (!autocomplete(passwordInput).includes('current-password') && !loginHint.test(metadata))) return null;
                const names = inputs.filter(input => ['text', 'email', 'tel'].includes(input.type) && form.contains(input) && editableVisible(input) && !autocomplete(input).includes('one-time-code'));
                const explicit = names.filter(input => autocomplete(input).includes('username'));
                const emails = names.filter(input => input.type === 'email');
                const choices = explicit.length ? explicit : emails.length ? emails : names;
                if (choices.length > 1) return null;
                return { form, passwordInput, usernameInput: choices[0] || null, shape: action.href + '\n' + metadata };
            }
            function sameForm(a, b) {
                return a && b && a.form === b.form && a.passwordInput === b.passwordInput && a.usernameInput === b.usernameInput && a.shape === b.shape;
            }
            function candidate() {
                if (discoveryDirty) {
                    passwordInputs.clear();
                    discoverPasswords(document);
                    discoveryDirty = false;
                }
                if (!passwordInputs.size) { entry = null; return null; }
                const passwordForms = new Set([...passwordInputs].map(input => input.form).filter(Boolean));
                const forms = [...document.forms].slice(0, 100).filter(form => passwordForms.has(form));
                let found = null;
                for (const form of forms) { found = analyze(form); if (found) break; }
                if (!found) { entry = null; return null; }
                if (!entry || entry.used || entry.frameURL !== location.href || !sameForm(entry.analysis, found)) {
                    entry = { token: crypto.randomUUID(), frameURL: location.href, analysis: found, used: false };
                }
                return entry;
            }
            function report() {
                scheduled = false;
                // Background document editors can keep mutating their DOM.
                // Metadata is only useful while the page is visible; the next
                // visibility event refreshes the index before detecting forms.
                if (document.visibilityState !== 'visible') return;
                const current = candidate();
                const fieldTypes = current ? (current.analysis.usernameInput ? [current.analysis.usernameInput.type, 'password'] : ['password']) : [];
                const payload = { token: current ? current.token : '', frameURL: location.href, fieldTypes };
                const serialized = JSON.stringify(payload);
                if (serialized === lastSent) return;
                lastSent = serialized;
                try { window.webkit.messageHandlers.nousPasswordCandidate.postMessage(payload); } catch (_) {}
            }
            function schedule() {
                if (scheduled || document.visibilityState !== 'visible') return;
                scheduled = true;
                setTimeout(report, 60);
            }
            function discoverPasswords(root) {
                if (root instanceof HTMLInputElement && root.type === 'password') passwordInputs.add(root);
                if (!(root instanceof Element || root instanceof Document)) return;
                for (const input of root.querySelectorAll('input[type="password" i]')) passwordInputs.add(input);
            }
            function observeChanges(records) {
                if (document.visibilityState !== 'visible') { discoveryDirty = true; return; }
                for (const record of records) {
                    if (record.type === 'childList') {
                        for (const node of record.addedNodes) discoverPasswords(node);
                    } else if (record.type === 'attributes' && record.target instanceof HTMLInputElement && record.attributeName === 'type') {
                        if (record.target.type === 'password') passwordInputs.add(record.target);
                        else passwordInputs.delete(record.target);
                    }
                }
                for (const input of passwordInputs) {
                    if (!input.isConnected || input.ownerDocument !== document) passwordInputs.delete(input);
                }
                // Text edits, canvas selections and layout/class changes on a
                // page without password fields cannot produce a login form.
                // New fields and text -> password changes are indexed above.
                if (passwordInputs.size || entry) schedule();
            }
            function currentEntry(expectedOrigin, token) {
                if (document.visibilityState !== 'visible' || !secureDocument() || location.origin !== expectedOrigin || !entry || entry.used || entry.token !== token || entry.frameURL !== location.href) return null;
                const checked = analyze(entry.analysis.form);
                return sameForm(entry.analysis, checked) ? entry : null;
            }
            function fill(username, password, expectedOrigin, token) {
                const current = currentEntry(expectedOrigin, token);
                if (!current) return { ok: false, reason: 'stale' };
                const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
                let didFillUsername = false;
                if (current.analysis.usernameInput && username) {
                    setter.call(current.analysis.usernameInput, username);
                    current.analysis.usernameInput.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
                    current.analysis.usernameInput.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
                    didFillUsername = true;
                }
                // Username input handlers can replace fields or change actions.
                // Recheck immediately before the password setter, without await.
                if (currentEntry(expectedOrigin, token) !== current) return { ok: false, reason: 'stale' };
                current.used = true;
                setter.call(current.analysis.passwordInput, password);
                current.analysis.passwordInput.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
                current.analysis.passwordInput.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
                schedule();
                return { ok: true, didFillUsername };
            }
            function refreshCandidate() {
                entry = null;
                lastSent = '';
                report();
            }
            if (!secureDocument()) return;
            Object.defineProperty(globalThis, '__nousBrowserPasswordAutofill', { value: Object.freeze({ fill, refreshCandidate }), configurable: false, writable: false });
            const observer = new MutationObserver(observeChanges);
            function start() {
                observer.observe(document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true,
                    attributeFilter: ['type', 'autocomplete', 'hidden', 'style', 'class', 'disabled', 'readonly', 'action', 'target', 'formaction', 'formtarget', 'inert', 'aria-hidden', 'form', 'id', 'name', 'aria-label', 'value'] });
                schedule();
            }
            if (document.documentElement) start(); else document.addEventListener('DOMContentLoaded', start, { once: true });
            document.addEventListener('DOMContentLoaded', schedule);
            document.addEventListener('focusin', schedule);
            window.addEventListener('resize', schedule);
            window.addEventListener('scroll', schedule, { passive: true });
            window.addEventListener('hashchange', schedule);
            window.addEventListener('popstate', schedule);
            window.addEventListener('pageshow', refreshCandidate);
            document.addEventListener('visibilitychange', () => {
                discoveryDirty = true;
                schedule();
            });
        })();
        """#
    }
}
