import AppKit
import Foundation
import Testing
import WebKit
@testable import NousBrowser

@Suite("Browser history integration", .serialized)
@MainActor
struct BrowserHistoryIntegrationTests {
    private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test
    func managerRecordsWebKitNavigationAndTitleChangesAndFlushesOnTermination() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let tabID = UUID()
        let sessionURL = directory.appendingPathComponent("session.json")
        let session = BrowserSession(tabs: [.init(id: tabID, title: "Blank", url: nil)],
                                     selectedTabID: tabID, isSidebarVisible: true)
        try JSONEncoder().encode(session).write(to: sessionURL)
        let defaultsDomain = "NousBrowserHistoryIntegrationTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        defer { defaults.removePersistentDomain(forName: defaultsDomain) }
        let manager = BrowserWindowManager(workspace: BrowserWorkspaceStore(sessionURL: sessionURL),
                                           appearance: BrowserAppearanceSettings(defaults: defaults),
                                           preferences: BrowserPreferences(defaults: defaults),
                                           showsWindows: false, startsHibernationMonitors: false)
        defer {
            manager.prepareForTermination()
            manager.windows.forEach { $0.window.close() }
        }

        manager.restoreWindows()
        let controller = try #require(manager.activeController)
        let model = controller.model
        let tab = try #require(model.selectedTab)
        #expect(tab.id == tabID)
        #expect(controller.history === manager.history)
        #expect(model.onVisit != nil)
        #expect(model.onPageTitleChanged != nil)
        #expect(manager.history.entries.isEmpty)

        let firstURL = URL(string: "https://history-integration.example.test/start")!
        let secondURL = URL(string: "https://history-integration.example.test/guide/second")!
        tab.webView.loadHTMLString("<!doctype html><title>First guide</title><p>Local history fixture</p>",
                                   baseURL: firstURL)
        let firstRecorded = try await waitUntil {
            !tab.webView.isLoading && manager.history.entries.contains {
                $0.url == firstURL && $0.title == "First guide"
            }
        }
        try #require(firstRecorded, "The initial in-memory page did not reach the manager's history store.")

        _ = try await tab.webView.evaluateJavaScript("""
        history.pushState({}, '', '/guide/second');
        document.title = 'Updated 中文 guide';
        true;
        """)
        let secondRecorded = try await waitUntil {
            manager.history.entries.contains {
                $0.url == secondURL && $0.title == "Updated 中文 guide"
            }
        }
        try #require(secondRecorded, "The same-document URL and title changes were not recorded.")
        #expect(Set(manager.history.entries.map { $0.url }) == [firstURL, secondURL])
        let beforeTitleChange = try #require(manager.history.entries.first { $0.url == secondURL })
        #expect(beforeTitleChange.visitCount == 1)

        _ = try await tab.webView.evaluateJavaScript("document.title = 'Final guide'; true;")
        let finalTitleRecorded = try await waitUntil {
            manager.history.entries.contains {
                $0.url == secondURL && $0.title == "Final guide"
            }
        }
        try #require(finalTitleRecorded, "The title-only update did not reach the history store.")
        let afterTitleChange = try #require(manager.history.entries.first { $0.url == secondURL })
        #expect(afterTitleChange.visitCount == beforeTitleChange.visitCount)
        #expect(afterTitleChange.lastVisited == beforeTitleChange.lastVisited)
        #expect(manager.history.entries.count == 2)
        let expectedHistory = manager.history.entries

        manager.prepareForTermination()
        let reloaded = BrowserHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        #expect(reloaded.entries == expectedHistory)
        #expect(Set(reloaded.entries.map { $0.url }) == [firstURL, secondURL])
        #expect(model.onVisit == nil)
        #expect(model.onPageTitleChanged == nil)
    }
}
