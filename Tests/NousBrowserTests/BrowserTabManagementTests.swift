import Foundation
import Testing
import WebKit
@testable import NousBrowser

@Suite("Pinning and duplicating tabs")
struct BrowserTabManagementTests {
    @MainActor private func fixture(_ tabs: [BrowserSession.Tab], selected: UUID? = nil) throws -> (model: BrowserModel, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = BrowserSession(tabs: tabs, selectedTabID: selected ?? tabs.first?.id, isSidebarVisible: true)
        let file = directory.appendingPathComponent("session.json")
        try JSONEncoder().encode(session).write(to: file)
        return (BrowserModel(sessionURL: file, loadSelectedTab: false), directory)
    }

    @Test @MainActor func legacySessionsDefaultToUnpinnedWithoutReordering() throws {
        let first = UUID(), second = UUID(), third = UUID()
        let legacy: [String: Any] = [
            "tabs": [
                ["id": first.uuidString, "title": "First"],
                ["id": second.uuidString, "title": "Second"],
                ["id": third.uuidString, "title": "Third"]
            ],
            "selectedTabID": second.uuidString,
            "isSidebarVisible": true
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(BrowserSession.self, from: data)
        #expect(decoded.tabs.allSatisfy { !$0.isPinned })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.json")
        try data.write(to: file)
        let model = BrowserModel(sessionURL: file, loadSelectedTab: false)
        #expect(model.tabs.map(\.id) == [first, second, third])
        #expect(model.selectedTabID == second)
        #expect(model.tabs.allSatisfy { !$0.isPinned && $0.webView.url == nil })
    }

    @Test @MainActor func restoringPinsStablyPartitionsAndPersistsOrder() throws {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let setup = try fixture([
            .init(id: a, title: "A", url: nil),
            .init(id: b, title: "B", url: nil, isPinned: true),
            .init(id: c, title: "C", url: nil),
            .init(id: d, title: "D", url: nil, isPinned: true)
        ], selected: c)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let model = setup.model
        #expect(model.tabs.map(\.id) == [b, d, a, c])
        #expect(model.tabs.map(\.isPinned) == [true, true, false, false])
        #expect(model.selectedTabID == c)
        #expect(model.tabs.allSatisfy { $0.webView.url == nil })
        model.persistSession()
        let restored = BrowserModel(sessionURL: setup.directory.appendingPathComponent("session.json"), loadSelectedTab: false)
        #expect(restored.tabs.map(\.id) == [b, d, a, c])
        #expect(restored.tabs.map(\.isPinned) == [true, true, false, false])
        #expect(restored.selectedTabID == c)
    }

    @Test @MainActor func pinningMovesToFrontAndUnpinningMovesToNormalBoundaryWithoutReplacingViews() throws {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let setup = try fixture([a, b, c, d].map { .init(id: $0, title: "Tab", url: nil) }, selected: c)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let model = setup.model
        let original = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0.webView) })
        model.togglePin(b)
        #expect(model.tabs.map(\.id) == [b, a, c, d])
        model.togglePin(d)
        #expect(model.tabs.map(\.id) == [d, b, a, c])
        model.togglePin(c)
        #expect(model.tabs.map(\.id) == [c, d, b, a])
        model.togglePin(d)
        #expect(model.tabs.map(\.id) == [c, b, d, a])
        #expect(model.tabs.map(\.isPinned) == [true, true, false, false])
        #expect(model.selectedTabID == c)
        #expect(model.tabs.allSatisfy { $0.webView === original[$0.id] })
        let saved = try JSONDecoder().decode(BrowserSession.self, from: Data(contentsOf: setup.directory.appendingPathComponent("session.json")))
        #expect(saved.tabs.map(\.id) == [c, b, d, a])
        #expect(saved.tabs.map(\.isPinned) == [true, true, false, false])
    }

    @Test @MainActor func duplicateIsIndependentNormalTabBesideSourceWithSharedWebsiteStorage() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let setup = try fixture([a, b, c].map { .init(id: $0, title: "Blank", url: nil) })
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let model = setup.model
        let source = try #require(model.tabs.first { $0.id == b })
        model.duplicateTab(b)
        let duplicate = try #require(model.selectedTab)
        #expect(duplicate.id != source.id)
        #expect(duplicate.url == source.url)
        #expect(duplicate.title == source.title)
        #expect(duplicate !== source)
        #expect(duplicate.webView !== source.webView)
        #expect(duplicate.webView.configuration.websiteDataStore === source.webView.configuration.websiteDataStore)
        #expect(duplicate.webView.configuration.websiteDataStore.isPersistent)
        #expect(!duplicate.isPinned)
        #expect(!duplicate.hasWebContent)
        #expect(model.tabs.map(\.id) == [a, b, duplicate.id, c])
        model.closeTab(duplicate.id)
        #expect(model.tabs.contains { $0.id == b })
        #expect(model.tabs.first { $0.id == b }?.webView === source.webView)
    }

    @Test @MainActor func duplicatePinnedLocalPageGoesBelowPinsAndPreservesSource() throws {
        let a = UUID(), b = UUID(), normal = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let page = directory.appendingPathComponent("local.html")
        try "<!doctype html><title>Local page</title><p>Local fixture</p>".write(to: page, atomically: true, encoding: .utf8)
        let setup = try fixture([
            .init(id: a, title: "Local page", url: page, isPinned: true),
            .init(id: b, title: "Second pin", url: nil, isPinned: true),
            .init(id: normal, title: "Normal", url: nil)
        ])
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let model = setup.model
        let source = try #require(model.tabs.first { $0.id == a })
        model.duplicateTab(a)
        let duplicate = try #require(model.selectedTab)
        #expect(model.tabs.map(\.id) == [a, b, duplicate.id, normal])
        #expect(duplicate.url == page)
        #expect(duplicate.title == "Local page")
        #expect(!duplicate.isPinned)
        #expect(source.isPinned)
        #expect(source.webView.url == nil)
        #expect(duplicate.webView !== source.webView)
        #expect(duplicate.webView.configuration.websiteDataStore === source.webView.configuration.websiteDataStore)
    }

    @Test @MainActor func closingAndReopeningPinnedTabsPreservesGroupingIncludingLastTab() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let setup = try fixture([
            .init(id: a, title: "First pin", url: nil, isPinned: true),
            .init(id: b, title: "Second pin", url: nil, isPinned: true),
            .init(id: c, title: "Normal", url: nil)
        ], selected: c)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let model = setup.model
        model.closeTab(a)
        #expect(model.selectedTabID == c)
        model.restoreClosedTab()
        #expect(model.tabs.map(\.id) == [b, a, c])
        #expect(model.tabs.map(\.isPinned) == [true, true, false])
        #expect(model.selectedTabID == a)
        model.closeTab(c)
        model.closeTab(b)
        model.closeTab(a)
        let fallback = try #require(model.selectedTab)
        #expect(!fallback.isPinned)
        model.restoreClosedTab()
        #expect(model.tabs.map(\.id) == [a, fallback.id])
        #expect(model.tabs.map(\.isPinned) == [true, false])
        #expect(model.selectedTabID == a)
        model.newTab()
        #expect(model.tabs.first?.id == a)
        #expect(model.tabs.last?.isPinned == false)
    }
}
