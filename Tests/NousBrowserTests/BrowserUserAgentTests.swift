import Darwin
import Foundation
import Testing
import WebKit
@testable import NousBrowser

@Suite("Uniform desktop WebKit identity", .serialized)
@MainActor
struct BrowserUserAgentTests {
    @Test func preservesProvidedWebsiteDataScriptsAndPreferences() {
        let configuration = WKWebViewConfiguration()
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let scripts = WKUserContentController()
        scripts.addUserScript(WKUserScript(source: "window.popupMarker = true;", injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let preferences = WKPreferences()
        preferences.javaScriptCanOpenWindowsAutomatically = false
        preferences.minimumFontSize = 18
        configuration.websiteDataStore = dataStore
        configuration.userContentController = scripts
        configuration.preferences = preferences
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        BrowserUserAgent.configure(configuration)
        #expect(configuration.websiteDataStore === dataStore)
        #expect(configuration.userContentController === scripts)
        #expect(configuration.preferences === preferences)
        #expect(configuration.userContentController.userScripts.count == 1)
        #expect(configuration.userContentController.userScripts.first?.source == "window.popupMarker = true;")
        #expect(!configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(configuration.preferences.minimumFontSize == 18)
        #expect(!configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    @Test func normalAndInheritedPopupConfigurationsUseOneConsistentSuffix() throws {
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = "NousBrowser/0.9 Version/25.0 Safari/605.1.15 NousBrowser/0.9"
        BrowserUserAgent.configure(configuration)
        let first = try #require(configuration.applicationNameForUserAgent)
        BrowserUserAgent.configure(configuration)
        let popup = try #require(configuration.copy() as? WKWebViewConfiguration)
        BrowserUserAgent.configure(popup)
        #expect(configuration.applicationNameForUserAgent == first)
        #expect(popup.applicationNameForUserAgent == first)
        let tokens = first.split(separator: " ")
        #expect(tokens.count == 3)
        #expect(tokens[0] == "Version/\(BrowserUserAgent.compatibilityVersion)")
        #expect(tokens[1] == "Safari/605.1.15")
        #expect(tokens[2].hasPrefix("NousBrowser/"))
        #expect(!first.contains("Mozilla/") && !first.contains("Chrome/"))
    }

    @Test func capabilityVersionUsesTheTestedRuntimeFloor() {
        if #available(macOS 26.4, *) { #expect(BrowserUserAgent.compatibilityVersion == "26.4") }
        else { #expect(BrowserUserAgent.compatibilityVersion == "26.0") }
    }

    @Test func arbitrarySitesAndAuthEndpointsShareIdentityFromDocumentStart() async throws {
        let view = makeView()
        defer { view.stopLoading() }
        let native = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let nativeAgent = try #require(try await native.evaluateJavaScript("navigator.userAgent") as? String)
        var firstAgent: String?
        for address in ["https://slack.com/signin", "https://app.slack.com/client/fixture",
                        "https://accounts.google.com/", "https://mail.google.com/",
                        "https://docs.google.com/presentation/d/fixture", "https://docs.google.com/document/d/fixture",
                        "https://docs.google.com/spreadsheets/d/fixture", "https://dg01slides.zoom.us/p/fixture",
                        "https://docs.zoom.us/", "https://arbitrary.example.test:8443/anything", "about:blank"] {
            let title = UUID().uuidString
            view.loadHTMLString("<!doctype html><title>\(title)</title>", baseURL: URL(string: address))
            try await waitUntil { !view.isLoading && view.title == title }
            let ua = try #require(try await view.evaluateJavaScript("navigator.userAgent") as? String)
            if let firstAgent { #expect(ua == firstAgent) } else { firstAgent = ua }
            #expect(ua.hasPrefix(nativeAgent + " "))
            #expect(ua.contains(" Version/\(BrowserUserAgent.compatibilityVersion) Safari/605.1.15 NousBrowser/"))
            #expect(try await view.evaluateJavaScript("window.identityAtDocumentStart") as? String == ua)
            #expect((view.customUserAgent ?? "").isEmpty)
        }
    }

    @Test func coldHTTPRedirectsFramesWorkersAndFetchUseTheSameIdentity() async throws {
        let server = try await IdentityPageServer()
        defer { server.close() }
        let view = makeView()
        defer { view.stopLoading() }
        // A genuine 302 chain crosses 127.0.0.1 -> localhost -> 127.0.0.1.
        // The server records the actual request headers before serving any JS.
        view.load(URLRequest(url: server.url.appendingPathComponent("redirect")))
        try await waitUntil { !view.isLoading && view.title == "Identity ready" }
        let report = try #require(try await view.evaluateJavaScript("window.identityReport") as? [String: String])
        let ua = try #require(report["navigator"])
        #expect(report.count == 9)
        #expect(report.values.allSatisfy { $0 == ua })
        #expect(ua.contains(" Version/\(BrowserUserAgent.compatibilityVersion) Safari/605.1.15 NousBrowser/"))
        let requests = try await server.requests()
        for path in ["/redirect", "/redirect-final", "/identity", "/frame", "/worker.js", "/fetch"] {
            let matching = requests.filter { $0["path"] == path }
            #expect(!matching.isEmpty, Comment(rawValue: "Missing HTTP request for " + path))
            #expect(matching.allSatisfy { $0["ua"] == ua }, Comment(rawValue: path))
        }
    }

    @Test func actualBrowserTabRetainsIdentityAcrossReloadHistoryPopupAndHibernation() async throws {
        let server = try await IdentityPageServer()
        defer { server.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = BrowserModel(sessionURL: directory.appendingPathComponent("session.json"), restoreSession: false, loadSelectedTab: false)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        model.newTab(url: server.url.appendingPathComponent("first"))
        let tab = try #require(model.selectedTab)
        try await waitUntil { !tab.webView.isLoading && tab.webView.title == "first" }
        let ua = try #require(try await tab.webView.evaluateJavaScript("navigator.userAgent") as? String)
        #expect(try await tab.webView.evaluateJavaScript("window.requestIdentity") as? String == ua)
        tab.load(server.url.appendingPathComponent("second"))
        try await waitUntil { !tab.webView.isLoading && tab.webView.title == "second" }
        tab.webView.reload()
        try await waitUntil { !tab.webView.isLoading && tab.webView.title == "second" }
        tab.webView.goBack()
        try await waitUntil { !tab.webView.isLoading && tab.webView.title == "first" }
        tab.webView.goForward()
        try await waitUntil { !tab.webView.isLoading && tab.webView.title == "second" }
        #expect(try await tab.webView.evaluateJavaScript("navigator.userAgent") as? String == ua)
        #expect(try await tab.webView.evaluateJavaScript("window.requestIdentity") as? String == ua)

        _ = try await tab.webView.evaluateJavaScript("window.open('about:blank'); true")
        let popup = try #require(model.selectedTab)
        #expect(popup.id != tab.id)
        #expect(try await popup.webView.evaluateJavaScript("navigator.userAgent") as? String == ua)
        popup.load(server.url.appendingPathComponent("popup"))
        try await waitUntil { !popup.webView.isLoading && popup.webView.title == "popup" }
        #expect(try await popup.webView.evaluateJavaScript("window.requestIdentity") as? String == ua)
        #expect((popup.webView.customUserAgent ?? "").isEmpty)

        let oldView = tab.webView
        let hibernated = await model.hibernateBackgroundTabs(for: .critical)
        #expect(hibernated.contains(tab.id))
        #expect(tab.webView !== oldView)
        model.selectTab(tab.id)
        try await waitUntil { !tab.webView.isLoading && tab.webView.title == "second" }
        #expect(try await tab.webView.evaluateJavaScript("navigator.userAgent") as? String == ua)
        #expect(try await tab.webView.evaluateJavaScript("window.requestIdentity") as? String == ua)
        let requests = try await server.requests()
        #expect(requests.filter { ["/first", "/second", "/popup"].contains($0["path"] ?? "") }.allSatisfy { $0["ua"] == ua })
    }

    private func makeView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        BrowserUserAgent.configure(configuration)
        configuration.userContentController.addUserScript(WKUserScript(
            source: "window.identityAtDocumentStart = navigator.userAgent;", injectionTime: .atDocumentStart, forMainFrameOnly: false))
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw IdentityPageServer.Failure.timeout }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

/// Loopback-only HTTP evidence. No external website, cookies or credentials.
private struct IdentityPageServer {
    enum Failure: Error { case startup, timeout }
    let process: Process
    let url: URL

    init() async throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-u", "-c", Self.source]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            process.terminate(); throw Failure.startup
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var bytes: [UInt8] = []
        while ProcessInfo.processInfo.systemUptime < deadline {
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 10 { break }
                bytes.append(byte)
            } else if count < 0, errno == EAGAIN || errno == EINTR {
                try await Task.sleep(for: .milliseconds(10))
            } else { break }
        }
        guard let text = String(bytes: bytes, encoding: .utf8), let port = Int(text),
              let url = URL(string: "http://127.0.0.1:\(port)") else {
            process.terminate(); throw Failure.startup
        }
        self.process = process
        self.url = url
    }

    func close() { if process.isRunning { process.terminate() } }

    func requests() async throws -> [[String: String]] {
        let (data, _) = try await URLSession.shared.data(from: url.appendingPathComponent("requests"))
        return try JSONDecoder().decode([[String: String]].self, from: data)
    }

    private static let source = #"""
    import json, threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    records = []
    lock = threading.Lock()
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            path = self.path.split('?')[0]
            ua = self.headers.get('User-Agent', '')
            if path != '/requests':
                with lock: records.append({'path': path, 'ua': ua})
            if path in ['/redirect', '/redirect-final']:
                location = ('http://localhost:%d/redirect-final' if path == '/redirect' else 'http://127.0.0.1:%d/identity') % self.server.server_port
                self.send_response(302)
                self.send_header('Location', location)
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            content_type = 'text/html; charset=utf-8'
            if path == '/requests':
                with lock: body = json.dumps(records)
                content_type = 'application/json'
            elif path == '/fetch':
                body, content_type = json.dumps({'ua': ua}), 'application/json'
            elif path == '/worker.js':
                body = 'postMessage({navigator:navigator.userAgent,request:' + json.dumps(ua) + '});'
                content_type = 'application/javascript'
            elif path == '/frame':
                body = '<script>parent.postMessage({kind:"frame",navigator:navigator.userAgent,request:' + json.dumps(ua) + '},"*");</script>'
            elif path == '/identity':
                body = '''<!doctype html><title>Loading identity</title><script>
                window.requestIdentity = REQUEST_UA;
                (async () => {
                    const frame = new Promise(resolve => {
                        window.addEventListener('message', event => { if (event.data.kind === 'frame') resolve(event.data); });
                        const element = document.createElement('iframe');
                        element.src = location.origin.replace('127.0.0.1', 'localhost') + '/frame';
                        document.documentElement.append(element);
                    });
                    const worker = new Promise(resolve => {
                        const instance = new Worker('/worker.js');
                        instance.onmessage = event => { resolve(event.data); instance.terminate(); };
                    });
                    const [f, w, response] = await Promise.all([frame, worker, fetch('/fetch').then(r => r.json())]);
                    window.identityReport = {
                        navigator:navigator.userAgent, start:window.identityAtDocumentStart, request:window.requestIdentity,
                        frameNavigator:f.navigator, frameRequest:f.request,
                        workerNavigator:w.navigator, workerRequest:w.request, fetchRequest:response.ua,
                        appVersion:navigator.appVersion.replace(/^/, 'Mozilla/')
                    };
                    document.title = 'Identity ready';
                })();
                </script>'''.replace('REQUEST_UA', json.dumps(ua))
            else:
                body = '<!doctype html><title>' + path.lstrip('/') + '</title><script>window.requestIdentity=' + json.dumps(ua) + ';</script>'
            data = body.encode()
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(data)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
    """#
}
