import Darwin
import Foundation
import Testing
import WebKit
@testable import NousBrowser

@Suite("Tab hibernation policy")
struct TabHibernationPolicyTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func tab(_ minutesAgo: Double, selected: Bool = false, pinned: Bool = false,
                     loaded: Bool = true, capturing: Bool = false) -> TabHibernation.Candidate {
        .init(id: UUID(), isSelected: selected, isPinned: pinned, isLoaded: loaded,
              isCapturingMedia: capturing, lastActiveAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func idleUnloadsOnlyLongUnusedUnpinnedBackgroundPages() {
        let old = tab(45), recent = tab(10), oldPinned = tab(90, pinned: true)
        let oldSelected = tab(120, selected: true), oldUnloaded = tab(120, loaded: false)
        let oldCapturing = tab(120, capturing: true), boundary = tab(30)
        let result = TabHibernation.tabsToHibernate([old, recent, oldPinned, oldSelected, oldUnloaded, oldCapturing, boundary],
                                                    pressure: .idle, now: now)
        #expect(result == [old.id, boundary.id])
    }

    @Test func memoryWarningKeepsTheMostRecentPagesAndPins() {
        let tabs = [tab(1), tab(50), tab(5), tab(20), tab(2), tab(8, pinned: true), tab(0, selected: true)]
        let result = TabHibernation.tabsToHibernate(tabs, pressure: .warning, now: now)
        // Five unpinned background pages; the three most recent stay loaded.
        #expect(result == [tabs[1].id, tabs[3].id])
    }

    @Test func criticalMemoryUnloadsEveryEligibleBackgroundPageOldestFirst() {
        let tabs = [tab(1), tab(3, pinned: true), tab(2), tab(9, selected: true), tab(4, capturing: true), tab(7, loaded: false)]
        let result = TabHibernation.tabsToHibernate(tabs, pressure: .critical, now: now)
        #expect(result == [tabs[1].id, tabs[2].id, tabs[0].id])
    }
}

@Suite("Tab hibernation and crash recovery", .serialized)
@MainActor
struct BrowserTabHibernationTests {
    private func makeModel() -> (model: BrowserModel, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = BrowserModel(sessionURL: directory.appendingPathComponent("session.json"), restoreSession: false, loadSelectedTab: false)
        return (model, directory)
    }

    private func waitUntil(_ timeout: Double = 8, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                Issue.record("Timed out waiting for the page")
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func pageID(_ tab: BrowserTab) async throws -> String? {
        try await tab.webView.evaluateJavaScript("window.pageInstance") as? String
    }

    /// Waits until the tab shows a freshly loaded document.
    private func waitForReload(of tab: BrowserTab, replacing before: String?) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline {
            if !tab.webView.isLoading, let now = try? await pageID(tab), now != before { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("The page did not reload")
    }

    @Test func hibernationReleasesThePageAndRestoresItsHistory() async throws {
        let server = try await HibernationPageServer()
        defer { server.close() }
        let setup = makeModel()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let model = setup.model
        let first = server.url.appendingPathComponent("first")
        let second = server.url.appendingPathComponent("second")

        model.newTab(url: first)
        let tab = try #require(model.selectedTab)
        try await waitUntil { tab.webView.url == first && !tab.webView.isLoading }
        tab.load(second)
        try await waitUntil { tab.webView.url == second && !tab.webView.isLoading && tab.canGoBack }
        let liveWebView = tab.webView

        model.newTab()
        #expect(await model.hibernateBackgroundTabs(for: .critical) == [tab.id])
        #expect(tab.isHibernated)
        #expect(tab.webView !== liveWebView)
        #expect(tab.webView.url == nil)
        #expect(liveWebView.navigationDelegate == nil && liveWebView.superview == nil)
        #expect(tab.url == second && tab.title == "Second page")
        #expect(await model.hibernateBackgroundTabs(for: .critical).isEmpty)

        model.selectTab(tab.id)
        try await waitUntil { tab.webView.url == second && !tab.webView.isLoading }
        #expect(!tab.isHibernated)
        #expect(tab.webView.backForwardList.backItem?.url == first)
        try await waitUntil { tab.canGoBack }
    }

    @Test func idleCheckUnloadsOnlyPagesUnusedForLong() async throws {
        let server = try await HibernationPageServer()
        defer { server.close() }
        let setup = makeModel()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let model = setup.model
        var clock = Date()
        model.now = { clock }

        model.newTab(url: server.url.appendingPathComponent("first"))
        let background = try #require(model.selectedTab)
        try await waitUntil { background.webView.url != nil && !background.webView.isLoading }
        model.newTab(url: server.url.appendingPathComponent("second"))
        let shown = try #require(model.selectedTab)
        try await waitUntil { shown.webView.url != nil && !shown.webView.isLoading }

        clock += 10 * 60
        #expect(await model.hibernateBackgroundTabs(for: .idle).isEmpty)
        clock += 25 * 60
        #expect(await model.hibernateBackgroundTabs(for: .idle) == [background.id])
        #expect(!shown.isHibernated)
    }

    @Test func theVisiblePageReloadsAfterItsProcessEndsButNotInALoop() async throws {
        let server = try await HibernationPageServer()
        defer { server.close() }
        let setup = makeModel()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let model = setup.model
        model.newTab(url: server.url.appendingPathComponent("first"))
        let tab = try #require(model.selectedTab)
        try await waitUntil { tab.webView.url != nil && !tab.webView.isLoading }
        let before = try await pageID(tab)

        tab.webViewWebContentProcessDidTerminate(tab.webView)
        #expect(tab.errorDescription == nil)
        try await waitForReload(of: tab, replacing: before)

        // A second failure right after an automatic reload stops and explains.
        tab.webViewWebContentProcessDidTerminate(tab.webView)
        #expect(tab.errorDescription != nil)
    }

    @Test func aBackgroundPageReloadsWhenShownAfterItsProcessEnds() async throws {
        let server = try await HibernationPageServer()
        defer { server.close() }
        let setup = makeModel()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let model = setup.model
        model.newTab(url: server.url.appendingPathComponent("first"))
        let background = try #require(model.selectedTab)
        try await waitUntil { background.webView.url != nil && !background.webView.isLoading }
        let before = try await pageID(background)
        model.newTab()

        background.webViewWebContentProcessDidTerminate(background.webView)
        #expect(background.errorDescription == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await pageID(background) == before)

        model.selectTab(background.id)
        try await waitForReload(of: background, replacing: before)
        #expect(background.errorDescription == nil)
    }
}

/// Serves two small pages on loopback. Each load gets a new random
/// `window.pageInstance`, so a test can tell a reload from a cached page.
private struct HibernationPageServer {
    enum Failure: Error { case startup }
    let process: Process
    let url: URL

    init() async throws {
        let process = Process()
        let output = Pipe()
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
            } else {
                break
            }
        }
        guard let text = String(bytes: bytes, encoding: .utf8), let port = Int(text),
              let url = URL(string: "http://127.0.0.1:\(port)") else {
            process.terminate(); throw Failure.startup
        }
        self.process = process
        self.url = url
    }

    func close() { if process.isRunning { process.terminate() } }

    private static let source = #"""
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            title = 'Second page' if self.path.startswith('/second') else 'First page'
            html = ('<!doctype html><meta charset="utf-8"><title>' + title + '</title>'
                    '<script>window.pageInstance = String(Math.random());</script><p>' + title + '</p>')
            body = html.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
    """#
}
