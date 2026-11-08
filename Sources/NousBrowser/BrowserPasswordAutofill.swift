import Foundation

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

    static func testingHTTPAllowed(_ requested: Bool) -> Bool {
        #if DEBUG
        requested
        #else
        false
        #endif
    }

    static let fillSource = #"""
    const bridge = globalThis.__nousBrowserPasswordAutofill;
    if (!bridge) return { ok: false, reason: 'unavailable' };
    return bridge.fill(username, password, expectedOrigin, token);
    """#

    /// The detector runs only in Chromium's isolated script world. Page content
    /// cannot select the native binding or enable HTTP credential handling.
    static func detectionSource(allowLoopbackHTTPForTesting: Bool) -> String {
        let reportSource = "globalThis.__nousPasswordCandidate(serialized);"
        let pageShowSource = "window.addEventListener('pageshow', event => event.persisted ? refreshCandidate() : requestCandidate());"
        let discoverSource = "resetDiscovery();"
        let formsSource = "[...passwordForms].filter(form => form.isConnected).slice(0, 100)"
        let observerSource = chromiumObservationSource
        return "const allowLoopbackHTTP = \(allowLoopbackHTTPForTesting ? "true" : "false");\n" + #"""
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
                    \#(discoverSource)
                }
                if (!passwordInputs.size) { entry = null; return null; }
                const passwordForms = new Set([...passwordInputs].map(input => input.form).filter(Boolean));
                const forms = \#(formsSource);
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
                try { \#(reportSource) } catch (_) {}
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
            function requestCandidate() {
                // A metadata handshake must not revoke an unchanged, unused
                // form token while native state/load callbacks are in flight.
                // candidate() still rechecks origin, URL, fields and form shape.
                lastSent = '';
                report();
            }
            function refreshCandidate() {
                entry = null;
                requestCandidate();
            }
            if (!secureDocument()) return;
            Object.defineProperty(globalThis, '__nousBrowserPasswordAutofill', { value: Object.freeze({ fill, refreshCandidate, requestCandidate }), configurable: false, writable: false });
            \#(observerSource)
            document.addEventListener('DOMContentLoaded', schedule);
            document.addEventListener('focusin', schedule);
            window.addEventListener('resize', schedule);
            window.addEventListener('scroll', schedule, { passive: true });
            window.addEventListener('hashchange', schedule);
            window.addEventListener('popstate', schedule);
            \#(pageShowSource)
        })();
        """#
    }

    /// Chromium does not need a document-wide style/text observer on editors.
    /// Discovery is structural, coalesced and bounded; only indexed login forms
    /// and their ancestors get the more expensive candidate-state observation.
    private static let chromiumObservationSource = #"""
        const pendingRoots = new Set();
        let batch = [], batchRoots = null, walk = null;
        let discoveryHandle = null, usingIdle = false, observing = false;
        let watchedForms = new Set(), watchedAncestors = new Set();
        const formAttributes = ['type', 'autocomplete', 'hidden', 'style', 'class', 'disabled', 'readonly', 'action', 'target', 'formaction', 'formtarget', 'inert', 'aria-hidden', 'form', 'id', 'name', 'aria-label', 'value'];
        const ancestorAttributes = ['hidden', 'style', 'class', 'inert', 'aria-hidden'];
        const candidateObserver = new MutationObserver(() => schedule());
        function stopDiscovery() {
            if (discoveryHandle !== null) {
                if (usingIdle) cancelIdleCallback(discoveryHandle); else clearTimeout(discoveryHandle);
            }
            discoveryHandle = null;
            pendingRoots.clear(); batch = []; batchRoots = null; walk = null;
        }
        function queueDiscovery(root) {
            if (!(root instanceof Element || root instanceof Document) || !root.isConnected || !observing) return;
            if (!pendingRoots.has(document)) {
                // A mutation burst cannot retain an unbounded queue. Overflow
                // becomes one budgeted document traversal, not a synchronous scan.
                if (pendingRoots.size >= 256) { pendingRoots.clear(); pendingRoots.add(document); }
                else pendingRoots.add(root);
            }
            scheduleDiscovery();
        }
        function scheduleDiscovery() {
            if (discoveryHandle !== null || !observing || document.visibilityState !== 'visible') return;
            usingIdle = typeof requestIdleCallback === 'function';
            discoveryHandle = usingIdle ? requestIdleCallback(discoverChunk, {timeout:120}) : setTimeout(discoverChunk, 16);
        }
        function refreshFormObservers() {
            const forms = new Set(), ancestors = new Set();
            for (const input of passwordInputs) {
                if (!input.isConnected || input.ownerDocument !== document || input.type !== 'password') { passwordInputs.delete(input); continue; }
                const form = input.form;
                if (!form || !form.contains(input) || forms.size >= 100) continue;
                forms.add(form);
                for (let node = form.parentElement; node; node = node.parentElement) ancestors.add(node);
            }
            const equal = (a,b) => a.size === b.size && [...a].every(item => b.has(item));
            if (equal(forms, watchedForms) && equal(ancestors, watchedAncestors)) return;
            candidateObserver.disconnect();
            watchedForms = forms; watchedAncestors = ancestors;
            if (!observing) return;
            for (const form of forms) candidateObserver.observe(form, {subtree:true, childList:true, characterData:true, attributes:true, attributeFilter:formAttributes});
            // No subtree observation on ancestors: unrelated editor class/style
            // and text changes do not schedule form analysis.
            for (const node of ancestors) candidateObserver.observe(node, {attributes:true, attributeFilter:ancestorAttributes});
        }
        function discoverChunk() {
            discoveryHandle = null;
            if (!observing || document.visibilityState !== 'visible') return;
            const started = performance.now();
            let budget = 256, indexChanged = false;
            while (budget > 0 && performance.now() - started < 3) {
                budget--;
                if (!walk) {
                    if (!batch.length) {
                        if (!pendingRoots.size) break;
                        batch = [...pendingRoots]; batchRoots = new Set(batch); pendingRoots.clear();
                    }
                    const root = batch.pop();
                    if (!root.isConnected) continue;
                    let parent = root.parentNode, covered = false, depth = 0;
                    while (parent && depth++ < 256) {
                        if (batchRoots.has(parent)) { covered = true; break; }
                        parent = parent.parentNode;
                    }
                    if (covered) continue;
                    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
                    if (!(root instanceof Element)) budget--;
                    walk = {walker, node:root instanceof Element ? root : walker.nextNode()};
                }
                const node = walk.node;
                if (!node) { walk = null; continue; }
                walk.node = walk.walker.nextNode();
                if (node instanceof HTMLInputElement && node.isConnected && node.type === 'password' && !passwordInputs.has(node)) {
                    passwordInputs.add(node); indexChanged = true;
                }
            }
            if (indexChanged) { refreshFormObservers(); schedule(); }
            if (walk || batch.length || pendingRoots.size) scheduleDiscovery();
            else batchRoots = null;
        }
        const structureObserver = new MutationObserver(records => {
            if (!observing) return;
            let indexChanged = false, removed = false;
            for (const record of records) {
                if (record.type === 'attributes') {
                    const input = record.target;
                    if (input instanceof HTMLInputElement) {
                        if (input.type === 'password') { passwordInputs.add(input); indexChanged = true; }
                        else if (passwordInputs.delete(input)) indexChanged = true;
                    }
                } else {
                    removed ||= record.removedNodes.length > 0;
                    for (const node of record.addedNodes) {
                        queueDiscovery(node);
                        if (pendingRoots.has(document)) break;
                    }
                }
            }
            if (removed && passwordInputs.size) {
                for (const input of passwordInputs) if (!input.isConnected) { passwordInputs.delete(input); indexChanged = true; }
                // Reparenting may alter which ancestor controls form visibility.
                if (passwordInputs.size) refreshFormObservers();
            }
            if (indexChanged) { refreshFormObservers(); schedule(); }
        });
        function resetDiscovery() {
            discoveryDirty = false;
            stopDiscovery();
            passwordInputs.clear();
            refreshFormObservers();
            queueDiscovery(document);
        }
        function startObservation() {
            if (!document.documentElement || document.visibilityState !== 'visible') return;
            observing = true;
            structureObserver.observe(document.documentElement, {childList:true, subtree:true, attributes:true, attributeFilter:['type','form']});
            resetDiscovery();
            schedule();
        }
        if (document.documentElement) startObservation(); else document.addEventListener('DOMContentLoaded', startObservation, {once:true});
        document.addEventListener('visibilitychange', () => {
            structureObserver.disconnect(); candidateObserver.disconnect();
            observing = false; stopDiscovery();
            watchedForms.clear(); watchedAncestors.clear();
            entry = null; discoveryDirty = true;
            if (document.visibilityState === 'visible') startObservation();
        });
        window.addEventListener('pagehide', () => {
            structureObserver.disconnect(); candidateObserver.disconnect();
            observing = false; stopDiscovery();
            watchedForms.clear(); watchedAncestors.clear(); entry = null; discoveryDirty = true;
        });
        window.addEventListener('pageshow', event => { if (event.persisted) startObservation(); });
        """#
}
