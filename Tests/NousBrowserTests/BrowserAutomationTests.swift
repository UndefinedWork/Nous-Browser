import AppKit
import Darwin
import Foundation
import NousAutomation
import Testing
import WebKit
@testable import NousBrowser

@Suite("Browser MCP automation", .serialized)
@MainActor
struct BrowserAutomationTests {
    @Test func listingUsesStableIDsWithoutChangingTheActiveWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let first = try #require(fixture.manager.newWindow())
        let second = try #require(fixture.manager.newWindow())
        let result = await fixture.call("browser_list_windows")
        let list = try #require(result.result?.objectValue?["windows"]?.arrayValue)
        #expect(list.count == 2)
        #expect(Set(list.compactMap { $0.objectValue?["window_id"]?.stringValue }) == Set([first.session.id.uuidString, second.session.id.uuidString]))
        #expect(fixture.manager.activeWindowID == second.session.id)
        let tabs = await fixture.call("browser_list_tabs", ["window_id": .string(first.session.id.uuidString)])
        #expect(tabs.result?.objectValue?["tabs"]?.arrayValue?.count == 1)
        #expect(fixture.manager.activeWindowID == second.session.id)
    }

    @Test func newTabTargetsItsExplicitWindowAndInsertionPoint() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let first = try #require(fixture.manager.newWindow())
        let source = try #require(first.controller.model.selectedTabID)
        first.controller.model.newTab()
        let oldSecond = try #require(first.controller.model.selectedTabID)
        let other = try #require(fixture.manager.newWindow())
        let result = await fixture.call("browser_new_tab", ["window_id": .string(first.session.id.uuidString), "after_tab_id": .string(source.uuidString)])
        #expect(result.error == nil)
        let newID = try #require(result.result?.objectValue?["tab_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        #expect(first.controller.model.tabs.map(\.id) == [source, newID, oldSecond])
        #expect(other.controller.model.tabs.count == 1)
        #expect(!first.controller.isAddressPresented)
    }

    @Test func selectingAndClosingExplicitTabsDoesNotUseTheKeyWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let first = try #require(fixture.manager.newWindow())
        let firstTab = try #require(first.controller.model.selectedTabID)
        let second = try #require(fixture.manager.newWindow())
        let selected = await fixture.call("browser_select_tab", ["tab_id": .string(firstTab.uuidString)])
        #expect(selected.error == nil)
        #expect(fixture.manager.activeWindowID == first.session.id)
        fixture.manager.activate(second)
        let closed = await fixture.call("browser_close_tab", ["tab_id": .string(firstTab.uuidString)])
        #expect(closed.error == nil)
        #expect(fixture.manager.windows.map { $0.session.id } == [second.session.id])
        #expect(second.controller.model.tabs.count == 1)
    }

    @Test func missingAndStaleIDsNeverFallBackToTheActiveTab() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let context = try #require(fixture.manager.newWindow())
        let tabID = try #require(context.controller.model.selectedTabID)
        for request in [
            AutomationRequest(tool: "browser_close_tab"),
            AutomationRequest(tool: "browser_close_tab", arguments: ["tab_id": .string(UUID().uuidString)]),
            AutomationRequest(tool: "browser_new_tab", arguments: ["window_id": .string("not-a-window")]),
            AutomationRequest(tool: "browser_new_tab", arguments: ["window_id": .string(context.session.id.uuidString), "after_tab_id": .string(UUID().uuidString)])
        ] {
            #expect(await fixture.executor.execute(request).error != nil)
        }
        #expect(fixture.manager.windows.count == 1)
        #expect(context.controller.model.tabs.map(\.id) == [tabID])
    }

    @Test func executorEnforcesThePublicToolCatalogAtThePrivateBoundary() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        for request in [
            AutomationRequest(tool: "evaluate_javascript", arguments: ["script": .string("document.cookie")]),
            AutomationRequest(tool: "browser_list_windows", arguments: ["unexpected": .bool(true)]),
            AutomationRequest(tool: "browser_list_tabs", arguments: ["window_id": .number(1)])
        ] { #expect(await fixture.executor.execute(request).error != nil) }
        #expect(fixture.manager.windows.isEmpty)
    }

    @Test(arguments: ["file:///etc/passwd", "data:text/html,secret", "javascript:alert(1)", "mailto:user@example.test", "https://user:secret@example.test/", "example.test", "about:blank"])
    func unsupportedURLsCannotChangeATabOrCreateAWindow(candidate: String) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let context = try #require(fixture.manager.newWindow())
        let tab = try #require(context.controller.model.selectedTab)
        #expect(await fixture.call("browser_navigate", ["tab_id": .string(tab.id.uuidString), "url": .string(candidate)]).error != nil)
        #expect(await fixture.call("browser_new_window", ["url": .string(candidate)]).error != nil)
        #expect(tab.url == nil)
        #expect(fixture.manager.windows.count == 1)
    }

    @Test func emptyPagesCannotBeReadAndURLsNeverReturnEmbeddedCredentials() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let context = try #require(fixture.manager.newWindow())
        let tab = try #require(context.controller.model.selectedTab)
        #expect(await fixture.call("browser_snapshot", ["tab_id": .string(tab.id.uuidString)]).error != nil)
        tab.url = URL(string: "https://username:secret@example.test/path")
        let result = await fixture.call("browser_list_tabs")
        let data = try JSONEncoder().encode(result)
        #expect(!String(decoding: data, as: UTF8.self).contains("secret"))
        #expect(!String(decoding: data, as: UTF8.self).contains("username"))
    }

    @Test func snapshotExcludesFieldValuesHiddenTextAndPageWorldAccess() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let tab = try await fixture.loadPage()
        let snapshot = try await fixture.snapshot(tab)
        let data = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(data.contains("Visible fixture heading"))
        for secret in ["PASSWORD-SENTINEL", "TEXTAREA-SENTINEL", "INPUT-SENTINEL", "HIDDEN-SENTINEL"] {
            #expect(!data.contains(secret))
        }
        #expect(snapshot["elements"]?.arrayValue?.contains { $0.objectValue?["type"]?.stringValue == "password" } == true)
        let pageWorld = try await tab.webView.evaluateJavaScript("typeof window.__nousAutomationSnapshot")
        #expect(pageWorld as? String == "undefined")
    }

    @Test func fillAndClickDispatchPageEventsWithoutImplicitSubmission() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let tab = try await fixture.loadPage()
        let snapshot = try await fixture.snapshot(tab)
        let input = try fixture.args(snapshot, tab: tab, label: "Message")
        let fill = await fixture.call("browser_fill", input.merging(["text": .string("Synthetic 中文 message")]) { $1 })
        #expect(fill.error == nil)
        let inputValue = try await tab.webView.evaluateJavaScript("document.getElementById('message').value")
        #expect(inputValue as? String == "Synthetic 中文 message")
        let before = try await tab.webView.evaluateJavaScript("JSON.stringify(window.events)")
        #expect(before as? String == "{\"input\":1,\"change\":1,\"submit\":0,\"click\":0}")
        let click = await fixture.call("browser_click", try fixture.args(snapshot, tab: tab, label: "Count"))
        #expect(click.error == nil)
        let after = try await tab.webView.evaluateJavaScript("window.events.click")
        #expect(after as? Int == 1)
    }

    @Test func freshSnapshotsAndElementReplacementInvalidateOldReferences() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let tab = try await fixture.loadPage()
        let first = try await fixture.snapshot(tab)
        let oldArgs = try fixture.args(first, tab: tab, label: "Count")
        let second = try await fixture.snapshot(tab)
        #expect(await fixture.call("browser_click", oldArgs).error?.contains("stale") == true)
        let currentArgs = try fixture.args(second, tab: tab, label: "Count")
        _ = try await tab.webView.evaluateJavaScript("let button=document.getElementById('count'); button.replaceWith(button.cloneNode(true)); true")
        #expect(await fixture.call("browser_click", currentArgs).error?.contains("changed") == true)
        let beforeRevocation = try await fixture.snapshot(tab)
        let revokedArgs = try fixture.args(beforeRevocation, tab: tab, label: "Count")
        fixture.executor.invalidateSnapshots()
        #expect(await fixture.call("browser_click", revokedArgs).error?.contains("stale") == true)
        let count = try await tab.webView.evaluateJavaScript("window.events.click")
        #expect(count as? Int == 0)
    }

    @Test func passwordFileAndCoveredControlsAreRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let tab = try await fixture.loadPage()
        let snapshot = try await fixture.snapshot(tab)
        for label in ["Password", "Upload"] {
            let args = try fixture.args(snapshot, tab: tab, label: label)
            #expect(await fixture.call("browser_fill", args.merging(["text": .string("blocked")]) { $1 }).error != nil)
            #expect(await fixture.call("browser_click", args).error != nil)
        }
        let count = try fixture.args(snapshot, tab: tab, label: "Count")
        _ = try await tab.webView.evaluateJavaScript("let overlay=document.createElement('div');overlay.style='position:fixed;inset:0;z-index:999;background:white';document.body.append(overlay);true")
        #expect(await fixture.call("browser_click", count).error?.contains("covered") == true)
        let password = try await tab.webView.evaluateJavaScript("document.getElementById('password').value")
        #expect(password as? String == "PASSWORD-SENTINEL")
    }
}

@MainActor
private final class Fixture {
    let directory: URL
    let defaults: UserDefaults
    let defaultsDomain: String
    let manager: BrowserWindowManager
    let executor: BrowserAutomationExecutor
    private var server: FixtureServer?

    init() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Nous-MCP-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsDomain = "NousMCPTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: defaultsDomain)!
        manager = BrowserWindowManager(workspace: BrowserWorkspaceStore(sessionURL: directory.appendingPathComponent("session.json")),
            appearance: BrowserAppearanceSettings(defaults: defaults), preferences: BrowserPreferences(defaults: defaults),
            showsWindows: false, startsHibernationMonitors: false)
        executor = BrowserAutomationExecutor(windows: manager)
    }

    func call(_ tool: String, _ arguments: [String: JSONValue] = [:]) async -> AutomationResponse {
        await executor.execute(.init(tool: tool, arguments: arguments))
    }

    func loadPage() async throws -> BrowserTab {
        let server = try await FixtureServer()
        self.server = server
        let context = try #require(manager.newWindow())
        let tab = try #require(context.controller.model.selectedTab)
        // Keep these WebKit tests hidden and independent of the user's desktop.
        context.window.contentView = tab.webView
        tab.webView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        tab.load(server.url)
        for _ in 0..<200 {
            if tab.webView.url == server.url, !tab.webView.isLoading { return tab }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw AutomationError("Synthetic fixture load timed out.")
    }

    func snapshot(_ tab: BrowserTab) async throws -> [String: JSONValue] {
        let response = await call("browser_snapshot", ["tab_id": .string(tab.id.uuidString)])
        #expect(response.error == nil)
        return try #require(response.result?.objectValue)
    }

    func args(_ snapshot: [String: JSONValue], tab: BrowserTab, label: String) throws -> [String: JSONValue] {
        let id = try #require(snapshot["snapshot_id"])
        let ref = try #require(snapshot["elements"]?.arrayValue?.first { $0.objectValue?["name"]?.stringValue == label }?.objectValue?["ref"])
        return ["tab_id": .string(tab.id.uuidString), "snapshot_id": id, "ref": ref]
    }

    func close() {
        manager.prepareForTermination()
        manager.windows.forEach { $0.window.close() }
        server?.close()
        defaults.removePersistentDomain(forName: defaultsDomain)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class FixtureServer {
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
            let descriptor = output.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw AutomationError("Fixture startup failed.") }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            var bytes = [UInt8]()
            var complete = false
            while ProcessInfo.processInfo.systemUptime < deadline, bytes.count <= 5 {
                var byte: UInt8 = 0
                let count = Darwin.read(descriptor, &byte, 1)
                if count == 1 {
                    if byte == 10 { complete = true; break }
                    bytes.append(byte)
                } else if count == 0 { throw AutomationError("Fixture exited early.") }
                else if errno == EAGAIN || errno == EWOULDBLOCK { try await Task.sleep(for: .milliseconds(10)) }
                else if errno != EINTR { throw AutomationError("Fixture startup failed.") }
            }
            guard complete, let text = String(bytes: bytes, encoding: .utf8), let port = Int(text),
                  let url = URL(string: "http://127.0.0.1:\(port)/fixture") else { throw AutomationError("Fixture startup timed out.") }
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
            html = '''<!doctype html><meta charset="utf-8"><title>MCP Synthetic Fixture</title>
            <style>body{font:14px system-ui;margin:20px}label{display:block}input,textarea{height:24px;margin:4px}button{height:30px}</style>
            <h1>Visible fixture heading</h1><p hidden>HIDDEN-SENTINEL</p>
            <form id="form"><label>Message<input id="message" value="INPUT-SENTINEL"></label>
            <label>Password<input id="password" type="password" value="PASSWORD-SENTINEL"></label>
            <label>Upload<input type="file"></label><label>Notes<textarea id="notes">TEXTAREA-SENTINEL</textarea></label>
            <button type="button" aria-labelledby="notes" title="Safe fallback">No field value in name</button>
            <button id="count" type="button">Count</button><button type="submit">Submit</button></form>
            <script>window.events={input:0,change:0,submit:0,click:0};
            for(const type of ['input','change','submit'])document.addEventListener(type,e=>{window.events[type]++;if(type==='submit')e.preventDefault();});
            document.getElementById('count').onclick=()=>window.events.click++;</script>'''
            body=html.encode()
            self.send_response(200)
            self.send_header('Content-Type','text/html; charset=utf-8')
            self.send_header('Content-Length',str(len(body)))
            self.send_header('Cache-Control','no-store')
            self.end_headers()
            self.wfile.write(body)
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    print(server.server_port,flush=True)
    server.serve_forever()
    """#
}
