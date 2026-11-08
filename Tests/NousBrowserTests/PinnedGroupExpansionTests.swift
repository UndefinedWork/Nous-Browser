import Foundation
import Testing
@testable import NousBrowser

/// Pinned groups are shared by every window; opening or closing one is not.
@Suite("Pinned group expansion is per window", .serialized)
@MainActor
struct PinnedGroupExpansionTests {
    private func pinnedGroup(_ model: BrowserModel) -> TabGroup? {
        model.layout(for: model.activeSpaceID).pinned.lazy.compactMap(\.group).first
    }

    @Test func collapsingInOneWindowLeavesTheOtherAndSurvivesRestore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserSpaceStore(fileURL: directory.appendingPathComponent("spaces.json"))
        let first = BrowserModel(sessionURL: directory.appendingPathComponent("a.json"), restoreSession: false,
                                 loadSelectedTab: false, startWithBlankTab: true, spaceStore: store)
        let second = BrowserModel(sessionURL: directory.appendingPathComponent("b.json"), restoreSession: false,
                                  loadSelectedTab: false, startWithBlankTab: true, spaceStore: store)
        defer { second.shutdown() }

        first.newTab()
        let groupID = try #require(first.newGroup(containing: first.tabs.map(\.id), name: "Work"))
        first.toggleGroupPinned(groupID)
        #expect(pinnedGroup(first)?.isExpanded == true)
        #expect(pinnedGroup(second)?.id == groupID)
        #expect(pinnedGroup(second)?.tabIDs.count == 2)

        first.updateGroup(groupID, isExpanded: false)
        #expect(pinnedGroup(first)?.isExpanded == false)
        #expect(pinnedGroup(second)?.isExpanded == true)

        // Shared changes still reach every window without overriding its view.
        first.updateGroup(groupID, name: "Renamed")
        #expect(pinnedGroup(second)?.name == "Renamed")
        #expect(pinnedGroup(second)?.isExpanded == true)
        #expect(pinnedGroup(first)?.isExpanded == false)

        first.persistSession()
        first.shutdown()
        let restored = BrowserModel(sessionURL: directory.appendingPathComponent("a.json"),
                                    loadSelectedTab: false, spaceStore: store)
        defer { restored.shutdown() }
        #expect(pinnedGroup(restored)?.isExpanded == false)
        #expect(pinnedGroup(second)?.isExpanded == true)
    }
}
