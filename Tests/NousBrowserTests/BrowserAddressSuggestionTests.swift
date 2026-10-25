import Foundation
import Testing
@testable import NousBrowser

@Suite("Address suggestions")
struct BrowserAddressSuggestionTests {
    @MainActor
    private struct Fixture {
        let directory: URL
        let model: BrowserModel
        let history: BrowserHistoryStore
        let controller: BrowserController
    }

    @MainActor
    private func fixture(tabs: [BrowserSession.Tab] = []) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let initialTabs: [BrowserSession.Tab] = tabs.isEmpty ? [.init(id: UUID(), title: "Blank", url: nil)] : tabs
        let session = BrowserSession(tabs: initialTabs, selectedTabID: initialTabs.first?.id, isSidebarVisible: true)
        let sessionURL = directory.appendingPathComponent("session.json")
        try JSONEncoder().encode(session).write(to: sessionURL)
        let model = BrowserModel(sessionURL: sessionURL, loadSelectedTab: false)
        let history = BrowserHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let controller = BrowserController(model: model, history: history)
        return Fixture(directory: directory, model: model, history: history, controller: controller)
    }

    @MainActor
    private func tearDown(_ setup: Fixture) {
        setup.controller.shutdown()
        setup.history.flush()
        try? FileManager.default.removeItem(at: setup.directory)
    }

    @MainActor
    private func openTabIDs(_ suggestions: [BrowserAddressSuggestion]) -> [UUID] {
        suggestions.compactMap { suggestion in
            if case let .openTab(tab) = suggestion { return tab.id }
            return nil
        }
    }

    @MainActor
    private func visitedURLs(_ suggestions: [BrowserAddressSuggestion]) -> [URL] {
        suggestions.compactMap { suggestion in
            if case let .visitedPage(entry) = suggestion { return entry.url }
            return nil
        }
    }

    @Test @MainActor
    func oneCharacterMatchesAnOpenTitleAndAHistoryURL() throws {
        let tabID = UUID()
        let setup = try fixture(tabs: [
            .init(id: tabID, title: "Zebra notes", url: URL(string: "https://open.example.test/start")!),
            .init(id: UUID(), title: "Reference", url: URL(string: "https://other.example.test/reference")!)
        ])
        defer { tearDown(setup) }
        let historyURL = URL(string: "https://archive.example.test/z")!
        setup.history.recordVisit(url: historyURL, title: "Archive", at: Date())

        setup.controller.addressText = "z"
        let suggestions = setup.controller.addressSuggestions

        #expect(openTabIDs(suggestions) == [tabID])
        #expect(visitedURLs(suggestions) == [historyURL])
        #expect(suggestions.count == 2)
        #expect(setup.model.tabs.allSatisfy { $0.webView.url == nil })
    }

    @Test @MainActor
    func multipleTermsUseANDMatchingAcrossTitlesAndURLs() throws {
        let matchingID = UUID()
        let openURL = URL(string: "https://alpha.example.test/manual")!
        let setup = try fixture(tabs: [
            .init(id: matchingID, title: "Design notes", url: openURL),
            .init(id: UUID(), title: "Design only", url: URL(string: "https://beta.example.test/manual")!),
            .init(id: UUID(), title: "Reference only", url: URL(string: "https://alpha.example.test/reference")!)
        ])
        defer { tearDown(setup) }
        let historyURL = URL(string: "https://alpha.archive.test/manual")!
        setup.history.recordVisit(url: historyURL, title: "Design archive", at: Date())
        setup.history.recordVisit(url: URL(string: "https://beta.archive.test/manual")!, title: "Design only", at: Date())
        setup.history.recordVisit(url: URL(string: "https://alpha.archive.test/reference")!, title: "Reference only", at: Date())

        setup.controller.addressText = "design alpha"
        let suggestions = setup.controller.addressSuggestions
        #expect(openTabIDs(suggestions) == [matchingID])
        #expect(visitedURLs(suggestions) == [historyURL])
        #expect(Set(suggestions.map { $0.url }) == [openURL, historyURL])

        setup.controller.addressText = "alpha design"
        #expect(Set(setup.controller.addressSuggestions.map { $0.id }) == Set(suggestions.map { $0.id }))
    }

    @Test @MainActor
    func mixedChineseAndLatinQueriesIgnoreLatinCase() throws {
        let tabID = UUID()
        let setup = try fixture(tabs: [
            .init(id: tabID, title: "SWIFTUI 中文研究", url: URL(string: "https://open.example.test/research")!),
            .init(id: UUID(), title: "SwiftUI English reference", url: URL(string: "https://open.example.test/english")!)
        ])
        defer { tearDown(setup) }
        let historyURL = URL(string: "https://archive.example.test/design")!
        setup.history.recordVisit(url: historyURL, title: "SwiftUI 中文设计", at: Date())

        setup.controller.addressText = "sWiFtUi 中文"
        let suggestions = setup.controller.addressSuggestions

        #expect(openTabIDs(suggestions) == [tabID])
        #expect(visitedURLs(suggestions) == [historyURL])
        #expect(suggestions.count == 2)
    }

    @Test @MainActor
    func aChineseIdeographicDotMatchesTheSameDomainAsAnASCIIDot() throws {
        let tabID = UUID()
        let setup = try fixture(tabs: [
            .init(id: tabID, title: "Current guide", url: URL(string: "https://docs.example.test/guide")!)
        ])
        defer { tearDown(setup) }
        let historyURL = URL(string: "https://docs.example.test/archive")!
        setup.history.recordVisit(url: historyURL, title: "Archived guide", at: Date())

        setup.controller.addressText = "docs。example。test"
        let suggestions = setup.controller.addressSuggestions
        #expect(openTabIDs(suggestions) == [tabID])
        #expect(visitedURLs(suggestions) == [historyURL])

        setup.controller.addressText = "docs.example.test"
        #expect(Set(setup.controller.addressSuggestions.map { $0.id }) == Set(suggestions.map { $0.id }))
    }

    @Test @MainActor
    func fragmentVariantsDeduplicateOpenTabsAndHistoryIntoOneOpenSuggestion() throws {
        let firstID = UUID(), secondID = UUID()
        let setup = try fixture(tabs: [
            .init(id: firstID, title: "Duplicate first", url: URL(string: "https://example.test/duplicate#first")!),
            .init(id: secondID, title: "Duplicate second", url: URL(string: "https://example.test/duplicate#second")!)
        ])
        defer { tearDown(setup) }
        setup.history.recordVisit(url: URL(string: "https://example.test/duplicate#archived")!, title: "Duplicate archive", at: Date())

        setup.controller.addressText = "duplicate"
        let suggestions = setup.controller.addressSuggestions

        #expect(suggestions.count == 1)
        let suggestion = try #require(suggestions.first)
        if case let .openTab(tab) = suggestion {
            #expect([firstID, secondID].contains(tab.id))
        } else {
            Issue.record("An existing open page should represent the deduplicated suggestion.")
        }
        #expect(visitedURLs(suggestions).isEmpty)
    }

    @Test @MainActor
    func combinedSuggestionsAreLimitedToSixUniquePages() throws {
        let tabs: [BrowserSession.Tab] = (0..<8).map { index in
            .init(id: UUID(), title: "Match open \(index)", url: URL(string: "https://open.example.test/match/\(index)")!)
        }
        let setup = try fixture(tabs: tabs)
        defer { tearDown(setup) }
        for index in 0..<5 {
            setup.history.recordVisit(url: URL(string: "https://archive.example.test/match/\(index)")!,
                                      title: "Match archive \(index)", at: Date())
        }

        setup.controller.addressText = "match"
        let suggestions = setup.controller.addressSuggestions

        #expect(suggestions.count == 6)
        #expect(Set(suggestions.map { $0.id }).count == 6)
        #expect(Set(suggestions.map { $0.url }).count == 6)
        #expect(setup.model.tabs.allSatisfy { $0.webView.url == nil })
    }

    @Test @MainActor
    func historyFromAnotherWindowIsSuggestedWithoutAnOpenTabInTheCurrentWindow() throws {
        let setup = try fixture()
        defer { tearDown(setup) }
        let otherURL = URL(string: "https://other-window.example.test/research")!
        let otherID = UUID()
        let otherSession = BrowserSession(
            tabs: [.init(id: otherID, title: "Other window research", url: otherURL)],
            selectedTabID: otherID, isSidebarVisible: true)
        let otherSessionURL = setup.directory.appendingPathComponent("other-window-session.json")
        try JSONEncoder().encode(otherSession).write(to: otherSessionURL)
        let otherModel = BrowserModel(sessionURL: otherSessionURL, loadSelectedTab: false)
        defer { otherModel.shutdown() }
        let otherTab = try #require(otherModel.selectedTab)
        setup.history.recordVisit(url: try #require(otherTab.url), title: otherTab.title, at: Date())

        setup.controller.addressText = "other window"
        let suggestions = setup.controller.addressSuggestions

        #expect(setup.model.tabs.allSatisfy { $0.url != otherURL })
        #expect(openTabIDs(suggestions).isEmpty)
        #expect(visitedURLs(suggestions) == [otherURL])
        #expect(otherTab.webView.url == nil)
        #expect(setup.model.tabs.allSatisfy { $0.webView.url == nil })
    }
}
