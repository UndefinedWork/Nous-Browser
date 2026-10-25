import AppKit
import Foundation
import Testing
@testable import NousBrowser

@Suite("Tab reordering previews")
struct TabReorderingTests {
    @Test func finalIndicesWorkInBothDirectionsAndPreserveOtherRelativeOrder() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let order = [a, b, c, d]
        #expect(TabReordering.moving(b, in: order, pinnedIDs: [], to: 3) == [a, c, d, b])
        #expect(TabReordering.moving(d, in: order, pinnedIDs: [], to: 1) == [a, d, b, c])
        #expect(TabReordering.moving(c, in: order, pinnedIDs: [], to: 2) == order)
        #expect(order == [a, b, c, d])
    }

    @Test func missingIDsAndExtremeIndicesAreSafe() {
        let a = UUID(), b = UUID(), c = UUID(), missing = UUID()
        let order = [a, b, c]
        #expect(TabReordering.destinationIndex(for: missing, in: order, pinnedIDs: [], proposedIndex: 1) == nil)
        #expect(TabReordering.moving(missing, in: order, pinnedIDs: [], to: 1) == order)
        #expect(TabReordering.destinationIndex(for: a, in: [], pinnedIDs: [], proposedIndex: 0) == nil)
        #expect(TabReordering.moving(c, in: order, pinnedIDs: [], to: .min) == [c, a, b])
        #expect(TabReordering.moving(a, in: order, pinnedIDs: [], to: .max) == [b, c, a])
        #expect(TabReordering.moving(a, in: [a], pinnedIDs: [a], to: .max) == [a])
    }

    @Test func pinnedAndNormalGroupsCannotBeCrossedByDragging() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        let order = [a, b, c, d, e]
        let pins: Set<UUID> = [a, b, UUID()]
        #expect(TabReordering.destinationIndex(for: a, in: order, pinnedIDs: pins, proposedIndex: 4) == 1)
        #expect(TabReordering.moving(a, in: order, pinnedIDs: pins, to: 4) == [b, a, c, d, e])
        #expect(TabReordering.destinationIndex(for: e, in: order, pinnedIDs: pins, proposedIndex: 0) == 2)
        #expect(TabReordering.moving(e, in: order, pinnedIDs: pins, to: 0) == [a, b, e, c, d])
        #expect(TabReordering.moving(c, in: order, pinnedIDs: pins, to: 0) == order)
        #expect(TabReordering.moving(b, in: [a, b], pinnedIDs: [a, b], to: 100) == [a, b])
    }
}

@Suite("Committed tab reordering")
struct BrowserTabReorderingTests {
    @MainActor private func fixture() throws -> (model: BrowserModel, directory: URL, ids: [UUID]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ids = (0..<5).map { _ in UUID() }
        let tabs = ids.enumerated().map { index, id in
            BrowserSession.Tab(id: id, title: "Local \(index)",
                               url: directory.appendingPathComponent("\(index).html"), isPinned: index < 2)
        }
        let session = BrowserSession(tabs: tabs, selectedTabID: ids[3], isSidebarVisible: true)
        let file = directory.appendingPathComponent("session.json")
        try JSONEncoder().encode(session).write(to: file)
        return (BrowserModel(sessionURL: file, loadSelectedTab: false), directory, ids)
    }

    @Test @MainActor func commitPreservesSelectionViewsIconsAndLazyPagesThenSurvivesRestart() throws {
        let setup = try fixture()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let model = setup.model
        let ids = setup.ids
        let originalTabs = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0) })
        let icon = NSImage(size: NSSize(width: 12, height: 12))
        for tab in model.tabs { tab.favicon = icon }
        model.moveTab(ids[2], to: 4)
        #expect(model.tabs.map(\.id) == [ids[0], ids[1], ids[3], ids[4], ids[2]])
        model.moveTab(ids[1], to: 0)
        let expected = [ids[1], ids[0], ids[3], ids[4], ids[2]]
        #expect(model.tabs.map(\.id) == expected)
        #expect(model.selectedTabID == ids[3])
        #expect(model.tabs.map(\.isPinned) == [true, true, false, false, false])
        #expect(model.tabs.allSatisfy { $0 === originalTabs[$0.id] })
        #expect(model.tabs.allSatisfy { $0.webView === originalTabs[$0.id]?.webView })
        #expect(model.tabs.allSatisfy { $0.webView.url == nil && !$0.isLoading && $0.favicon === icon })
        let file = setup.directory.appendingPathComponent("session.json")
        let saved = try JSONDecoder().decode(BrowserSession.self, from: Data(contentsOf: file))
        #expect(saved.tabs.map(\.id) == expected)
        let restored = BrowserModel(sessionURL: file, loadSelectedTab: false)
        #expect(restored.tabs.map(\.id) == expected)
        #expect(restored.tabs.map(\.isPinned) == [true, true, false, false, false])
        #expect(restored.selectedTabID == ids[3])
        #expect(restored.tabs.allSatisfy { $0.webView.url == nil && !$0.isLoading })
    }

    @Test @MainActor func invalidAndUnchangedMovesDoNotRewriteTheSession() throws {
        let setup = try fixture()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let file = setup.directory.appendingPathComponent("session.json")
        let timestamp = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
        let before = try Data(contentsOf: file)
        setup.model.moveTab(UUID(), to: 1)
        setup.model.moveTab(setup.ids[0], to: .min)
        setup.model.moveTab(setup.ids[2], to: 0)
        #expect(setup.model.tabs.map(\.id) == setup.ids)
        #expect(try Data(contentsOf: file) == before)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        #expect(after == timestamp)
    }

    @Test @MainActor func cancelingADraftPreviewLeavesTheModelAndSessionUntouched() throws {
        let setup = try fixture()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let file = setup.directory.appendingPathComponent("session.json")
        let before = try Data(contentsOf: file)
        let pins = Set(setup.model.tabs.filter(\.isPinned).map(\.id))
        let preview = TabReordering.moving(setup.ids[4], in: setup.ids, pinnedIDs: pins, to: 2)
        #expect(preview != setup.ids)
        #expect(setup.model.tabs.map(\.id) == setup.ids)
        #expect(setup.model.selectedTabID == setup.ids[3])
        #expect(try Data(contentsOf: file) == before)
        #expect(setup.model.tabs.allSatisfy { $0.webView.url == nil })
    }
}
