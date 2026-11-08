#if DEBUG
import AppKit
import Foundation
import Testing
@testable import NousBrowser

@Suite("Chromium lifecycle metadata is committed before rendering", .serialized)
@MainActor
struct ChromiumLifecycleMetadataTests {
    private struct Update: Equatable {
        let id: UUID
        let active: Bool
        let pinned: Bool
        let discardable: Bool
    }

    @MainActor private final class Recorder {
        var updates: [Update] = []
        var latest: [UUID: Update] = [:]
        func watch(_ tab: BrowserTab) {
            let id = tab.id
            tab.onNativeLifecycleUpdate = { [weak self] active, pinned, discardable in
                let update = Update(id: id, active: active, pinned: pinned, discardable: discardable)
                self?.updates.append(update)
                self?.latest[id] = update
            }
        }
    }

    private func model(in directory: URL, name: String, count: Int) -> BrowserModel {
        let model = BrowserModel(sessionURL: directory.appendingPathComponent(name + ".json"),
            restoreSession: false, loadSelectedTab: false, startWithBlankTab: true)
        for _ in 1..<count { model.newTab() }
        return model
    }

    @Test func selectionProtectsDestinationBeforeReleasingSourceWithoutADeck() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = model(in: directory, name: "selection", count: 2)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let first = model.tabs[0], second = model.tabs[1]
        let recorder = Recorder()
        model.tabs.forEach(recorder.watch)

        model.selectTab(first.id)

        #expect(recorder.updates == [
            Update(id: first.id, active: true, pinned: false, discardable: true),
            Update(id: second.id, active: false, pinned: false, discardable: true)
        ])
        #expect(first.webView.superview == nil && second.webView.superview == nil)
    }

    @Test func delayedDeckSnapshotCannotUnprotectTheCurrentSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = model(in: directory, name: "stale-deck", count: 2)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let oldSelection = try #require(model.selectedTabID)
        let newSelection = model.tabs[0]
        let staleTabs = model.tabs
        let recorder = Recorder()
        model.tabs.forEach(recorder.watch)
        model.selectTab(newSelection.id)

        WebViewDeckView().show(staleTabs, selectedID: oldSelection, owner: model)

        #expect(recorder.latest[newSelection.id]?.active == true)
        #expect(recorder.latest[oldSelection]?.active == false)
    }

    @Test func deckCannotRemoveTransferProtection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = model(in: directory, name: "transfer-deck", count: 2)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let moving = model.tabs[0]
        let recorder = Recorder()
        recorder.watch(moving)
        moving.prepareForNativeLifecycleTransfer()

        WebViewDeckView().show(model.tabs, selectedID: model.selectedTabID, owner: model)

        #expect(recorder.latest[moving.id] == Update(id: moving.id, active: true, pinned: false, discardable: false))
        moving.finishNativeLifecycleTransfer()
    }

    @Test func pinUpdatesNativeStateDuringReorderingWithSelectionUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = model(in: directory, name: "pin", count: 2)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let background = model.tabs[0]
        let selected = model.selectedTabID
        let recorder = Recorder()
        recorder.watch(background)

        model.togglePin(background.id)
        #expect(recorder.updates.last == Update(id: background.id, active: false, pinned: true, discardable: true))
        model.togglePin(background.id)
        #expect(recorder.updates.last == Update(id: background.id, active: false, pinned: false, discardable: true))
        #expect(model.selectedTabID == selected)
        #expect(recorder.updates.count == 2)
    }

    @Test func transferProtectsOwnerlessTabAndBothWindowSelections() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = model(in: directory, name: "source", count: 2)
        let destination = model(in: directory, name: "destination", count: 2)
        defer { source.shutdown(); destination.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let moving = source.tabs[0]
        let sourceSelected = try #require(source.selectedTabID)
        let previousDestination = try #require(destination.selectedTabID)
        let recorder = Recorder()
        (source.tabs + destination.tabs).forEach(recorder.watch)
        source.synchronizeChromiumLifecycleStates()
        destination.synchronizeChromiumLifecycleStates()
        recorder.updates.removeAll()

        #expect(source.takeTabForTransfer(moving.id) === moving)
        #expect(moving.owner == nil)
        #expect(recorder.updates.first == Update(id: moving.id, active: true, pinned: false, discardable: false))
        #expect(destination.adoptTransferredTab(moving, at: 0))

        let oldSelectionRelease = try #require(recorder.updates.firstIndex { $0.id == previousDestination && !$0.active })
        #expect(recorder.updates[..<oldSelectionRelease].contains { $0.id == moving.id && $0.active })
        #expect(recorder.latest[moving.id] == Update(id: moving.id, active: true, pinned: false, discardable: true))
        #expect(recorder.latest[sourceSelected]?.active == true)
        #expect(recorder.latest[previousDestination]?.active == false)
        #expect(source.selectedTabID == sourceSelected && destination.selectedTabID == moving.id)
    }

    @Test func detachedSelectedTabGetsNewWindowProtectionBeforeAnyViewExists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = model(in: directory, name: "source", count: 2)
        let moving = try #require(source.selectedTab)
        let remaining = source.tabs[0]
        let recorder = Recorder()
        source.tabs.forEach(recorder.watch)
        #expect(source.takeTabForTransfer(moving.id) === moving)
        let destination = BrowserModel(sessionURL: directory.appendingPathComponent("detached.json"),
            restoreSession: false, loadSelectedTab: false, initialTab: moving)
        defer { source.shutdown(); destination.shutdown(); try? FileManager.default.removeItem(at: directory) }

        #expect(recorder.updates.first == Update(id: moving.id, active: true, pinned: false, discardable: false))
        #expect(recorder.latest[remaining.id]?.active == true)
        #expect(recorder.latest[moving.id] == Update(id: moving.id, active: true, pinned: false, discardable: true))
        #expect(moving.owner === destination && moving.webView.superview == nil)
    }

    @Test func rejectedAdoptionKeepsProtectionUntilRollbackCompletes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = model(in: directory, name: "source", count: 2)
        let moving = source.tabs[0]
        let originalSelection = try #require(source.selectedTabID)
        let conflictingTab = BrowserTab(id: moving.id, owner: nil)
        let destination = BrowserModel(sessionURL: directory.appendingPathComponent("conflict.json"),
            restoreSession: false, loadSelectedTab: false, initialTab: conflictingTab)
        defer { source.shutdown(); destination.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let recorder = Recorder()
        source.tabs.forEach(recorder.watch)

        #expect(source.takeTabForTransfer(moving.id) === moving)
        #expect(!destination.adoptTransferredTab(moving, at: 0))
        #expect(recorder.latest[moving.id]?.discardable == false)
        #expect(moving.owner == nil)
        #expect(source.adoptTransferredTab(moving, at: 0))
        source.selectTab(originalSelection)
        #expect(recorder.latest[originalSelection]?.active == true)
        #expect(recorder.latest[moving.id] == Update(id: moving.id, active: false, pinned: false, discardable: true))
    }
}
#endif
