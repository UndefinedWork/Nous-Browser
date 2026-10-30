import AppKit
import Darwin
import Foundation
import Testing
import WebKit
@testable import NousBrowser

@Suite("Password autofill boundaries", .serialized)
struct BrowserPasswordAutofillTests {
    @Test(.enabled(if: PasswordAutofillTestEnvironment.isHosted, "Requires the AppKit integration host"))
    @MainActor func editingWithoutLoginFieldsDoesNotRescanForms() async throws {
        let fixture = try await AutofillFixture(measureDetectionWork: true)
        defer { fixture.close() }
        try await fixture.load("/editor")
        try await Task.sleep(for: .milliseconds(200))
        try await fixture.resetDetectionWork()
        _ = try await fixture.webView.callAsyncJavaScript(#"""
        const editor = document.getElementById('editor');
        for (let index = 0; index < 12; index++) {
            editor.firstChild.nodeValue = 'Editing slide ' + index;
            editor.className = 'selection-' + index;
            editor.style.transform = `translateX(${index % 2}px)`;
            const selection = document.createElement('span');
            selection.textContent = 'selection';
            editor.append(selection);
            selection.remove();
            await new Promise(resolve => setTimeout(resolve, 100));
        }
        return true;
        """#, arguments: [:], in: nil, contentWorld: .page)
        let work = try await fixture.detectionWork()
        print("[Autofill editor mutations] \(work)")
        #expect(work["formCollections"] == 0)
        #expect(work["formElements"] == 0)
        #expect(work["geometryReads"] == 0)
        #expect(fixture.candidate == nil)
    }

    @Test(.enabled(if: PasswordAutofillTestEnvironment.isHosted, "Requires the AppKit integration host"))
    @MainActor func dynamicPasswordFieldsAndRemovedFormsRefreshCandidates() async throws {
        let fixture = try await AutofillFixture()
        defer { fixture.close() }
        try await fixture.load("/editor")
        _ = try await fixture.webView.evaluateJavaScript(#"""
        document.body.innerHTML = '<form id="login" action="/session"><input id="username" type="email" autocomplete="username"><input id="password" type="text" autocomplete="current-password"><button>Sign in</button></form>';
        true;
        """#)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.candidate == nil)
        _ = try await fixture.webView.evaluateJavaScript("document.getElementById('password').type='password'; true")
        let original = try await fixture.waitForCandidate()
        #expect(original.fieldTypes == ["email", "password"])
        _ = try await fixture.webView.evaluateJavaScript("window.removedLogin = document.getElementById('login'); removedLogin.remove(); true")
        try await fixture.waitForNoCandidate()
        _ = try await fixture.webView.evaluateJavaScript("document.body.append(removedLogin); true")
        let restored = try await fixture.waitForCandidate()
        #expect(restored.token != original.token)
    }

    @Test(.enabled(if: PasswordAutofillTestEnvironment.isHosted, "Requires the AppKit integration host"))
    @MainActor func backgroundMutationsDeferDetectionUntilVisible() async throws {
        let fixture = try await AutofillFixture(measureDetectionWork: true)
        defer { fixture.close() }
        try await fixture.load("/login")
        _ = try await fixture.waitForCandidate()
        fixture.webView.isHidden = true
        try await fixture.waitForVisibility("hidden")
        try await fixture.resetDetectionWork()
        _ = try await fixture.webView.callAsyncJavaScript(#"""
        for (let index = 0; index < 6; index++) {
            document.getElementById('login').className = 'state-' + index;
            document.querySelector('button').textContent = 'Sign in ' + index;
            await new Promise(resolve => setTimeout(resolve, 100));
        }
        document.getElementById('login').outerHTML = '<form id="login" action="/session"><input id="replacement" type="password" autocomplete="current-password"><button>Sign in</button></form>';
        return true;
        """#, arguments: [:], in: nil, contentWorld: .page)
        let work = try await fixture.detectionWork()
        print("[Autofill hidden mutations] \(work)")
        #expect(work["formCollections"] == 0)
        #expect(work["formElements"] == 0)
        #expect(work["geometryReads"] == 0)
        fixture.candidate = nil
        fixture.webView.isHidden = false
        try await fixture.waitForVisibility("visible")
        let candidate = try await fixture.waitForCandidate()
        #expect(candidate.fieldTypes == ["password"])
        _ = try await BrowserPasswordAutofill.fill(.init(username: "", password: "synthetic-only"), in: fixture.webView,
                                                 expectedOrigin: candidate.origin, token: candidate.token)
        #expect(try await fixture.webView.evaluateJavaScript("document.getElementById('replacement').value") as? String == "synthetic-only")
    }

    @Test @MainActor func originsAreExactHTTPSOrigins() throws {
        let first = try #require(BrowserPasswordAutofill.Origin(url: URL(string: "https://example.test/login")!))
        #expect(first == BrowserPasswordAutofill.Origin(url: URL(string: "https://example.test:443/other")!))
        #expect(first != BrowserPasswordAutofill.Origin(url: URL(string: "https://example.test:444/login")!))
        #expect(first != BrowserPasswordAutofill.Origin(url: URL(string: "https://sub.example.test/login")!))
        #expect(BrowserPasswordAutofill.Origin(url: URL(string: "http://example.test/login")!) == nil)
        #expect(BrowserPasswordAutofill.Origin(url: URL(string: "https://user:secret@example.test/login")!) == nil)
        #expect(first.url.absoluteString == "https://example.test")
    }

    @Test(.enabled(if: PasswordAutofillTestEnvironment.isHosted, "Requires Scripts/run-password-autofill-tests.sh with a real AppKit event loop"))
    @MainActor func fillsSyntheticValuesWithEventsWithoutSubmitting() async throws {
        let fixture = try await AutofillFixture()
        defer { fixture.close() }
        try await fixture.load("/login")
        let candidate = try await fixture.waitForCandidate()
        #expect(candidate.fieldTypes == ["email", "password"])
        let values = BrowserPasswordAutofill.Values(username: "synthetic@example.test", password: "synthetic-'\"\\-秘密")
        let result = try await BrowserPasswordAutofill.fill(values, in: fixture.webView, expectedOrigin: candidate.origin, token: candidate.token)
        #expect(result.didFillUsername)
        let username = try await fixture.webView.evaluateJavaScript("document.getElementById('username').value")
        let password = try await fixture.webView.evaluateJavaScript("document.getElementById('password').value")
        let events = try await fixture.webView.evaluateJavaScript("JSON.stringify(window.fixtureEvents)")
        #expect(username as? String == values.username)
        #expect(password as? String == values.password)
        #expect(events as? String == "{\"input\":2,\"change\":2,\"submit\":0}")
        let exposedHandler = try await fixture.webView.evaluateJavaScript("typeof window.webkit?.messageHandlers?.nousPasswordCandidate")
        #expect(exposedHandler as? String == "undefined")
    }

    @Test(arguments: ["/signup", "/new-password", "/hidden", "/cross-action", "/iframe", "/covered"])
    @MainActor func unsafeOrEmbeddedFormsDoNotBecomeCandidates(path: String) async throws {
        let fixture = try await AutofillFixture()
        defer { fixture.close() }
        try await fixture.load(path)
        try await Task.sleep(for: .seconds(1))
        #expect(fixture.candidate == nil)
    }

    @Test @MainActor func ordinaryHTTPIsDisabledByDefault() async throws {
        let fixture = try await AutofillFixture(allowTestHTTP: false)
        defer { fixture.close() }
        try await fixture.load("/login")
        try await Task.sleep(for: .seconds(1))
        #expect(fixture.candidate == nil)
    }

    @Test(.enabled(if: PasswordAutofillTestEnvironment.isHosted, "Requires Scripts/run-password-autofill-tests.sh with a real AppKit event loop"))
    @MainActor func changingActionAfterDetectionCannotReceivePassword() async throws {
        let fixture = try await AutofillFixture()
        defer { fixture.close() }
        try await fixture.load("/login")
        let candidate = try await fixture.waitForCandidate()
        _ = try await fixture.webView.evaluateJavaScript("document.getElementById('login').action='https://unrelated.invalid/session'; true")
        do {
            _ = try await BrowserPasswordAutofill.fill(.init(username: "synthetic", password: "synthetic-only"), in: fixture.webView,
                                                     expectedOrigin: candidate.origin, token: candidate.token)
            Issue.record("An unsafe form action was accepted")
        } catch BrowserPasswordAutofill.Failure.staleDocument {}
        let password = try await fixture.webView.evaluateJavaScript("document.getElementById('password').value")
        #expect(password as? String == "")
    }

    @Test(.enabled(if: PasswordAutofillTestEnvironment.isHosted, "Requires Scripts/run-password-autofill-tests.sh with a real AppKit event loop"))
    @MainActor func usernameEventCannotRedirectThePasswordToANewFormAction() async throws {
        let fixture = try await AutofillFixture()
        defer { fixture.close() }
        try await fixture.load("/mutate-on-username")
        let candidate = try await fixture.waitForCandidate()
        do {
            _ = try await BrowserPasswordAutofill.fill(.init(username: "synthetic", password: "synthetic-only"), in: fixture.webView,
                                                     expectedOrigin: candidate.origin, token: candidate.token)
            Issue.record("The password was filled after a username event changed the action")
        } catch BrowserPasswordAutofill.Failure.staleDocument {}
        let password = try await fixture.webView.evaluateJavaScript("document.getElementById('password').value")
        #expect(password as? String == "")
    }

    @Test(.enabled(if: PasswordAutofillTestEnvironment.isHosted, "Requires Scripts/run-password-autofill-tests.sh with a real AppKit event loop"))
    @MainActor func navigationInvalidatesTheOldToken() async throws {
        let fixture = try await AutofillFixture()
        defer { fixture.close() }
        try await fixture.load("/login")
        let old = try await fixture.waitForCandidate()
        try await fixture.load("/alternate")
        let current = try await fixture.waitForCandidate()
        #expect(old.token != current.token)
        do {
            _ = try await BrowserPasswordAutofill.fill(.init(username: "synthetic", password: "synthetic-only"), in: fixture.webView,
                                                     expectedOrigin: old.origin, token: old.token)
            Issue.record("A token from a previous document was accepted")
        } catch BrowserPasswordAutofill.Failure.staleDocument {}
        let password = try await fixture.webView.evaluateJavaScript("document.getElementById('password').value")
        #expect(password as? String == "")
    }

    @Test(.enabled(if: PasswordAutofillTestEnvironment.isHosted, "Requires the AppKit integration host"))
    @MainActor func restoredDocumentAndNativeRefreshReportFreshMetadata() async throws {
        let fixture = try await AutofillFixture()
        defer { fixture.close() }
        try await fixture.load("/login")
        let original = try await fixture.waitForCandidate()
        fixture.candidate = nil
        // A persisted pageshow deliberately reuses this document's JS state,
        // unlike a reload, and exercises BFCache's entry/lastSent lifetime.
        _ = try await fixture.webView.evaluateJavaScript("window.dispatchEvent(new PageTransitionEvent('pageshow', {persisted:true})); true")
        let restored = try await fixture.waitForCandidate()
        #expect(restored.token != original.token)
        #expect(restored.frameURL == original.frameURL)
        fixture.candidate = nil
        fixture.attachment?.refreshCandidate()
        let refreshed = try await fixture.waitForCandidate()
        #expect(refreshed.token != restored.token)
        #expect(refreshed.fieldTypes == ["email", "password"])
        let password = try await fixture.webView.evaluateJavaScript("document.getElementById('password').value")
        let events = try await fixture.webView.evaluateJavaScript("JSON.stringify(window.fixtureEvents)")
        #expect(password as? String == "")
        #expect(events as? String == "{\"input\":0,\"change\":0,\"submit\":0}")
    }

    @Test(.enabled(if: PasswordAutofillTestEnvironment.isHosted, "Requires Scripts/run-password-autofill-tests.sh with a real AppKit event loop"))
    @MainActor func cancellationAndHiddenPagesCannotReceiveCredentials() async throws {
        let fixture = try await AutofillFixture()
        defer { fixture.close() }
        try await fixture.load("/login")
        let candidate = try await fixture.waitForCandidate()
        let values = BrowserPasswordAutofill.Values(username: "synthetic@example.test", password: "synthetic-only")
        let operation = Task { @MainActor in
            try await BrowserPasswordAutofill.fill(values, in: fixture.webView, expectedOrigin: candidate.origin, token: candidate.token)
        }
        operation.cancel()
        do {
            _ = try await operation.value
            Issue.record("A pre-cancelled operation dispatched a fill")
        } catch is CancellationError {}
        fixture.webView.isHidden = true
        try await fixture.waitForVisibility("hidden")
        do {
            _ = try await BrowserPasswordAutofill.fill(values, in: fixture.webView, expectedOrigin: candidate.origin, token: candidate.token)
            Issue.record("A hidden document accepted credentials")
        } catch BrowserPasswordAutofill.Failure.staleDocument {}
        let password = try await fixture.webView.evaluateJavaScript("document.getElementById('password').value")
        #expect(password as? String == "")
        fixture.webView.isHidden = false
        try await fixture.waitForVisibility("visible")
        _ = try await BrowserPasswordAutofill.fill(values, in: fixture.webView, expectedOrigin: candidate.origin, token: candidate.token)
        let visiblePassword = try await fixture.webView.evaluateJavaScript("document.getElementById('password').value")
        #expect(visiblePassword as? String == values.password)
    }

    @Test(.enabled(if: PasswordAutofillTestEnvironment.isHosted, "Requires the AppKit integration host"))
    @MainActor func sharedPopupControllerKeepsBothAttachmentsWorking() async throws {
        let controller = WKUserContentController()
        let first = try await AutofillFixture(controller: controller)
        let second = try await AutofillFixture(controller: controller)
        defer { first.close(); second.close() }
        try await first.load("/login")
        _ = try await first.waitForCandidate()
        try await second.load("/login")
        _ = try await second.waitForCandidate()
        second.attachment?.invalidate()
        second.attachment = nil
        try await first.load("/alternate")
        let refreshed = try await first.waitForCandidate()
        #expect(refreshed.frameURL.path == "/alternate")
    }
}

nonisolated private enum PasswordAutofillTestEnvironment {
    static var isHosted: Bool { ProcessInfo.processInfo.environment["NOUS_BROWSER_PASSWORD_AUTOFILL_TEST_HOST"] == "1" }
}

@MainActor
private final class AutofillFixture {
    let server: AutofillFixtureServer
    let webView: WKWebView
    let window: NSWindow
    var attachment: BrowserPasswordAutofill.Attachment?
    var candidate: BrowserPasswordAutofill.Candidate?

    init(allowTestHTTP: Bool = true, controller: WKUserContentController? = nil, measureDetectionWork: Bool = false) async throws {
        let application = NSApplication.shared
        server = try await AutofillFixtureServer()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let controller { configuration.userContentController = controller }
        if measureDetectionWork {
            configuration.userContentController.addUserScript(WKUserScript(source: #"""
            globalThis.fixtureDetectionWork = {formCollections:0, formElements:0, geometryReads:0};
            function countGetter(prototype, property, counter) {
                const original = Object.getOwnPropertyDescriptor(prototype, property);
                Object.defineProperty(prototype, property, {...original, get() {
                    fixtureDetectionWork[counter]++;
                    return original.get.call(this);
                }});
            }
            countGetter(Document.prototype, 'forms', 'formCollections');
            countGetter(HTMLFormElement.prototype, 'elements', 'formElements');
            const originalRect = Element.prototype.getBoundingClientRect;
            Element.prototype.getBoundingClientRect = function() {
                fixtureDetectionWork.geometryReads++;
                return originalRect.call(this);
            };
            """#, injectionTime: .atDocumentStart, forMainFrameOnly: true,
            in: .world(name: "NousBrowserPasswordAutofill")))
        }
        BrowserPasswordAutofill.install(configuration: configuration, allowLoopbackHTTPForTesting: allowTestHTTP)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Local Autofill Test"
        window.contentView = webView
        if PasswordAutofillTestEnvironment.isHosted {
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            application.activate(ignoringOtherApps: true)
        }
        attachment = BrowserPasswordAutofill.attach(to: webView, allowLoopbackHTTPForTesting: allowTestHTTP) { [weak self] in self?.candidate = $0 }
    }

    func load(_ path: String) async throws {
        candidate = nil
        if PasswordAutofillTestEnvironment.isHosted { window.makeKeyAndOrderFront(nil) }
        let url = server.url.appendingPathComponent(String(path.dropFirst()))
        webView.load(URLRequest(url: url))
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(25))
            if webView.url == url, !webView.isLoading {
                if PasswordAutofillTestEnvironment.isHosted { try await waitForVisibility("visible") }
                return
            }
        }
        throw FixtureFailure.timeout("load \(path), current=\(webView.url?.path ?? "none"), loading=\(webView.isLoading), serverRunning=\(server.process.isRunning)")
    }

    func waitForCandidate() async throws -> BrowserPasswordAutofill.Candidate {
        for _ in 0..<200 {
            if let candidate { return candidate }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw FixtureFailure.timeout("candidate on \(webView.url?.path ?? "no document"), loading=\(webView.isLoading), attachment=\(attachment?.candidate != nil)")
    }

    func waitForNoCandidate() async throws {
        for _ in 0..<100 {
            if candidate == nil { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw FixtureFailure.timeout("candidate invalidation")
    }

    func waitForVisibility(_ expected: String) async throws {
        for _ in 0..<100 {
            let state = try await webView.evaluateJavaScript("document.visibilityState")
            if state as? String == expected { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        print("[AutofillFixture] visibilityTimeout expected=\(expected) windowVisible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) webViewHidden=\(webView.isHidden) appRunning=\(NSApp.isRunning) appActive=\(NSApp.isActive) appHidden=\(NSApp.isHidden) policy=\(NSApp.activationPolicy().rawValue)")
        throw FixtureFailure.timeout("visibility \(expected)")
    }

    func resetDetectionWork() async throws {
        _ = try await webView.evaluateJavaScript("Object.keys(fixtureDetectionWork).forEach(key => fixtureDetectionWork[key] = 0); true",
                                                 in: nil, contentWorld: .world(name: "NousBrowserPasswordAutofill"))
    }

    func detectionWork() async throws -> [String: Int] {
        try #require(try await webView.evaluateJavaScript("fixtureDetectionWork", in: nil,
                                                         contentWorld: .world(name: "NousBrowserPasswordAutofill")) as? [String: Int])
    }

    func close() {
        attachment?.invalidate()
        attachment = nil
        webView.stopLoading()
        window.contentView = nil
        window.close()
        server.close()
    }
}

private enum FixtureFailure: Error { case startup, timeout(String) }

@MainActor
private final class AutofillFixtureServer {
    let process: Process
    let url: URL

    init() async throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.source]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            // FileHandle.read(upToCount:) can wait to fill the entire buffer.
            // A nonblocking pipe plus bounded async polling keeps MainActor free.
            let descriptor = output.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw FixtureFailure.startup }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            var bytes: [UInt8] = []
            var receivedNewline = false
            while ProcessInfo.processInfo.systemUptime < deadline && bytes.count <= 5 {
                var byte: UInt8 = 0
                let count = Darwin.read(descriptor, &byte, 1)
                if count == 1 {
                    if byte == 10 { receivedNewline = true; break }
                    bytes.append(byte)
                } else if count == 0 {
                    throw FixtureFailure.startup
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    try await Task.sleep(for: .milliseconds(10))
                } else if errno != EINTR {
                    throw FixtureFailure.startup
                }
            }
            guard receivedNewline, let text = String(bytes: bytes, encoding: .utf8), let port = Int(text),
                  (1...65_535).contains(port), let url = URL(string: "http://127.0.0.1:\(port)") else { throw FixtureFailure.startup }
            self.process = process
            self.url = url
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    func close() { if process.isRunning { process.terminate() } }

    private static let source = #"""
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            form = '''<form id="login" action="/session" method="post">
            <label>Username<input id="username" type="email" autocomplete="username"></label>
            <label>Password<input id="password" type="password" autocomplete="current-password"></label>
            <button type="submit">Sign in</button></form>'''
            if self.path == '/signup': form = form.replace('id="login"', 'id="signup"').replace('Sign in', 'Create account')
            if self.path == '/new-password': form = form.replace('current-password', 'new-password')
            if self.path == '/hidden': form = form.replace('id="password"', 'id="password" style="opacity:0"')
            if self.path == '/cross-action': form = form.replace('action="/session"', 'action="https://unrelated.invalid/session"')
            if self.path == '/iframe': form = '<iframe src="/inner" width="600" height="400"></iframe>'
            if self.path == '/covered': form += '<div style="position:fixed;inset:0;background:white;z-index:99">Covered</div>'
            if self.path == '/editor': form = '<div id="editor" contenteditable="true">Slide text</div>' + ''.join('<form><input type="text" aria-label="Property"></form>' for _ in range(60))
            script = '''window.fixtureEvents={input:0,change:0,submit:0};
            for(const type of ['input','change','submit'])document.addEventListener(type,e=>{window.fixtureEvents[type]++;if(type==='submit')e.preventDefault();});'''
            if self.path == '/mutate-on-username': script += "document.getElementById('username').addEventListener('input',()=>document.getElementById('login').action='https://unrelated.invalid/session');"
            html = '<!doctype html><meta charset="utf-8"><title>Local Autofill Fixture</title><style>body{margin:20px;font:14px system-ui}input{display:block;width:280px;height:30px;margin:8px 0 16px}button{height:30px}</style>' + form + '<script>' + script + '</script>'
            body = html.encode()
            self.send_response(200)
            self.send_header('Content-Type','text/html; charset=utf-8')
            self.send_header('Content-Length',str(len(body)))
            self.send_header('Cache-Control','no-store')
            self.end_headers()
            self.wfile.write(body)
    # WebKit may open an idle/preconnect socket before the next navigation.
    # A single-threaded server can block on that socket indefinitely.
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    print(server.server_port,flush=True)
    server.serve_forever()
    """#
}
