import AppKit
import Foundation
import Testing
import WebKit
@testable import NousBrowser

@Suite("Page find state and asynchronous isolation", .serialized)
@MainActor
struct BrowserPageFindTests {
    @MainActor private final class FinderSpy {
        struct Request {
            let view: WKWebView
            let query: String
            let backwards: Bool
            let caseSensitive: Bool
            let wraps: Bool
            let complete: BrowserPageFindController.Completion
        }
        var requests: [Request] = []

        func find(_ view: WKWebView, query: String, configuration: WKFindConfiguration,
                  completion: @escaping BrowserPageFindController.Completion) {
            requests.append(Request(view: view, query: query, backwards: configuration.backwards,
                                    caseSensitive: configuration.caseSensitive, wraps: configuration.wraps,
                                    complete: completion))
        }
    }

    @MainActor private struct Fixture {
        let directory: URL
        let model: BrowserModel
        let spy: FinderSpy
        let find: BrowserPageFindController
        func cleanUp() {
            find.shutdown()
            model.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func fixture(tabCount: Int = 1) throws -> Fixture {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.json")
        let tabs = (0..<tabCount).map {
            BrowserSession.Tab(id: UUID(), title: "Find fixture \($0)", url: URL(string: "about:blank")!)
        }
        let session = BrowserSession(tabs: tabs, selectedTabID: tabs.first?.id, isSidebarVisible: true)
        try JSONEncoder().encode(session).write(to: file)
        let model = BrowserModel(sessionURL: file, loadSelectedTab: false)
        let spy = FinderSpy()
        let find = BrowserPageFindController(model: model, debounceInterval: .milliseconds(30),
                                             findOperation: spy.find)
        return Fixture(directory: directory, model: model, spy: spy, find: find)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "The synthetic find operation was not scheduled")
    }

    @Test func typingIsDebouncedAndUsesNativeCaseInsensitiveWrappedSearch() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        fixture.find.present()
        fixture.find.text = "First"
        fixture.find.text = "Second"
        fixture.find.text = "Alpha & 中文"
        try await waitUntil { fixture.spy.requests.count >= 1 }

        #expect(fixture.spy.requests.count == 1)
        let request = try #require(fixture.spy.requests.first)
        #expect(request.query == "Alpha & 中文")
        #expect(request.view === fixture.model.selectedTab?.webView)
        #expect(!request.caseSensitive)
        #expect(request.wraps)
        #expect(!request.backwards)
        request.complete(true)
        #expect(fixture.find.matchFound == true)
    }

    @Test func repeatedPresentFocusesWithoutHidingOrAdvancingTheMatch() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        fixture.find.present()
        fixture.find.text = "Fixture"
        try await waitUntil { fixture.spy.requests.count >= 1 }
        fixture.spy.requests[0].complete(true)
        let token = fixture.find.focusToken

        fixture.find.present()
        #expect(fixture.find.isPresented)
        #expect(fixture.find.focusToken != token)
        #expect(fixture.find.matchFound == true)
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.spy.requests.count == 1)
    }

    @Test func nextAndPreviousIgnoreOutOfOrderFindCompletions() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        fixture.find.present()
        fixture.find.text = "Fixture"
        try await waitUntil { fixture.spy.requests.count >= 1 }
        fixture.find.findNext()
        fixture.find.findNext(backward: true)

        #expect(fixture.spy.requests.count == 3)
        #expect(!fixture.spy.requests[1].backwards)
        #expect(fixture.spy.requests[2].backwards)
        fixture.spy.requests[1].complete(true)
        #expect(fixture.find.matchFound == nil)
        fixture.spy.requests[2].complete(false)
        #expect(fixture.find.matchFound == false)
        fixture.spy.requests[0].complete(true)
        #expect(fixture.find.matchFound == false)
    }

    @Test func dismissCancelsDebounceAndCannotBeRevivedByAnOldCompletion() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        fixture.find.present()
        fixture.find.text = "Remembered query"
        fixture.find.dismiss()
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.spy.requests.isEmpty)
        #expect(fixture.find.text == "Remembered query")

        fixture.find.present()
        try await waitUntil { fixture.spy.requests.count >= 1 }
        fixture.find.dismiss()
        fixture.spy.requests[0].complete(true)
        #expect(!fixture.find.isPresented)
        #expect(fixture.find.matchFound == nil)
    }

    @Test func sameURLReloadInvalidatesResultsUntilLoadingFinishes() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let tab = try #require(fixture.model.selectedTab)
        fixture.find.present()
        fixture.find.text = "Fixture"
        try await waitUntil { fixture.spy.requests.count >= 1 }

        tab.isLoading = true
        fixture.find.pageDidChange()
        fixture.spy.requests[0].complete(true)
        #expect(fixture.find.matchFound == nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.spy.requests.count == 1)

        tab.isLoading = false
        fixture.find.pageDidChange()
        try await waitUntil { fixture.spy.requests.count >= 2 }
        #expect(fixture.spy.requests[1].view === fixture.spy.requests[0].view)
        fixture.spy.requests[1].complete(false)
        #expect(fixture.find.matchFound == false)
    }

    @Test func changingTabsRoutesTheNextSearchToThatTabsWebView() async throws {
        let fixture = try fixture(tabCount: 2)
        defer { fixture.cleanUp() }
        fixture.find.present()
        fixture.find.text = "Fixture"
        try await waitUntil { fixture.spy.requests.count >= 1 }
        let second = fixture.model.tabs[1]
        fixture.model.selectTab(second.id)
        fixture.spy.requests[0].complete(true)
        #expect(fixture.find.matchFound == nil)

        try await waitUntil { second.webView.url != nil && !second.isLoading && !second.webView.isLoading }
        fixture.find.pageDidChange()
        try await waitUntil { fixture.spy.requests.count >= 2 }
        let latest = try #require(fixture.spy.requests.last)
        #expect(latest.view === second.webView)
        latest.complete(true)
        #expect(fixture.find.matchFound == true)
    }

    @Test func changingURLRejectsTheOldResultEvenBeforeTheViewChangeHookRuns() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        fixture.find.present()
        fixture.find.text = "Fixture"
        try await waitUntil { fixture.spy.requests.count >= 1 }
        fixture.model.selectedTab?.url = URL(string: "about:blank#another-route")
        fixture.spy.requests[0].complete(true)
        #expect(fixture.find.matchFound == nil)
        fixture.find.pageDidChange()
        try await waitUntil { fixture.spy.requests.count >= 2 }
        fixture.spy.requests[1].complete(true)
        #expect(fixture.find.matchFound == true)
    }

    @Test func selectingAnEmptyTabClosesTheBarAndFindNextCannotReopenIt() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        fixture.find.present()
        fixture.find.text = "Fixture"
        try await waitUntil { fixture.spy.requests.count >= 1 }
        fixture.model.newTab()
        fixture.find.pageDidChange()
        fixture.spy.requests[0].complete(true)
        fixture.find.findNext()
        fixture.find.present()
        #expect(!fixture.find.isPresented)
        #expect(fixture.find.matchFound == nil)
        #expect(fixture.spy.requests.count == 1)
    }

    @Test func shutdownDropsItsModelAndIgnoresPendingAndFutureSearches() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        fixture.find.present()
        fixture.find.text = "Fixture"
        try await waitUntil { fixture.spy.requests.count >= 1 }
        fixture.find.shutdown()
        fixture.spy.requests[0].complete(true)
        fixture.find.present()
        fixture.find.findNext()
        fixture.find.pageDidChange()
        #expect(fixture.find.model == nil)
        #expect(!fixture.find.isPresented)
        #expect(fixture.find.text.isEmpty)
        #expect(fixture.find.matchFound == nil)
        #expect(fixture.spy.requests.count == 1)
    }
}
