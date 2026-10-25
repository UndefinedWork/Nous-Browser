import Foundation
import Testing
import WebKit
@testable import NousBrowser

@Suite("Window session persistence")
struct BrowserWorkspaceStoreTests {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("session.json")
    }

    @Test @MainActor func migratesLegacySessionWithoutChangingTabs() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let id = UUID()
        let session = BrowserSession(tabs: [.init(id: id, title: "Saved page", url: nil, isPinned: true)],
                                     selectedTabID: id, isSidebarVisible: false, sidebarWidth: 320)
        let original = try JSONEncoder().encode(session)
        try original.write(to: file)
        let store = BrowserWorkspaceStore(sessionURL: file)
        let window = try #require(store.restoredWindows.first)
        #expect(window.usesLegacySession)
        #expect(store.sessionURL(for: window) == file)
        let model = BrowserModel(sessionURL: store.sessionURL(for: window), loadSelectedTab: false)
        #expect(model.tabs.map(\.id) == [id])
        #expect(model.selectedTab?.isPinned == true)
        #expect(!model.isSidebarVisible && model.sidebarWidth == 320)
        try store.save(windows: [window], activeWindowID: window.id)
        #expect(try Data(contentsOf: file) == original)
        #expect(BrowserWorkspaceStore(sessionURL: file).restoredWindows == [window])
        model.shutdown()
    }

    @Test @MainActor func restoresIndependentWindowsWithSharedWebsiteStorage() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = BrowserWorkspaceStore(sessionURL: file)
        let first = store.makeWindowSession()
        let second = store.makeWindowSession()
        #expect(store.sessionURL(for: first) != store.sessionURL(for: second))
        let firstModel = BrowserModel(sessionURL: store.sessionURL(for: first), restoreSession: false,
                                      loadSelectedTab: false, startWithBlankTab: true)
        let secondModel = BrowserModel(sessionURL: store.sessionURL(for: second), restoreSession: false,
                                       loadSelectedTab: false, startWithBlankTab: true)
        #expect(firstModel.selectedTab?.url == nil && secondModel.selectedTab?.url == nil)
        #expect(firstModel.selectedTab?.webView !== secondModel.selectedTab?.webView)
        #expect(firstModel.selectedTab?.webView.configuration.websiteDataStore ===
                secondModel.selectedTab?.webView.configuration.websiteDataStore)
        firstModel.newTab()
        firstModel.resizeSidebar(to: 350)
        firstModel.isSidebarVisible = false
        firstModel.persistSession()
        secondModel.resizeSidebar(to: 210)
        secondModel.persistSession()
        try store.save(windows: [first, second], activeWindowID: second.id)

        let restoredStore = BrowserWorkspaceStore(sessionURL: file)
        #expect(restoredStore.restoredWindows == [first, second])
        #expect(restoredStore.restoredActiveWindowID == second.id)
        let restoredFirst = BrowserModel(sessionURL: restoredStore.sessionURL(for: first), loadSelectedTab: false, startWithBlankTab: true)
        let restoredSecond = BrowserModel(sessionURL: restoredStore.sessionURL(for: second), loadSelectedTab: false, startWithBlankTab: true)
        #expect(restoredFirst.tabs.count == 2 && restoredSecond.tabs.count == 1)
        #expect(restoredFirst.selectedTabID == firstModel.selectedTabID)
        #expect(restoredSecond.selectedTabID == secondModel.selectedTabID)
        #expect(!restoredFirst.isSidebarVisible && restoredSecond.isSidebarVisible)
        #expect(restoredFirst.sidebarWidth == 350 && restoredSecond.sidebarWidth == 210)
        [firstModel, secondModel, restoredFirst, restoredSecond].forEach { $0.shutdown() }
    }

    @Test @MainActor func closingOneWindowKeepsOtherSessionsAndReleasesItsDelegates() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = BrowserWorkspaceStore(sessionURL: file)
        let first = store.makeWindowSession()
        let second = store.makeWindowSession()
        let firstModel = BrowserModel(sessionURL: store.sessionURL(for: first), restoreSession: false, loadSelectedTab: false, startWithBlankTab: true)
        let secondModel = BrowserModel(sessionURL: store.sessionURL(for: second), restoreSession: false, loadSelectedTab: false, startWithBlankTab: true)
        firstModel.newTab()
        secondModel.persistSession()
        let otherSnapshot = try Data(contentsOf: store.sessionURL(for: second))
        firstModel.shutdown()
        firstModel.shutdown()
        #expect(firstModel.tabs.count == 2)
        #expect(firstModel.tabs.allSatisfy { $0.webView.navigationDelegate == nil && $0.webView.uiDelegate == nil && $0.passwordCandidate == nil })
        try store.save(windows: [second], activeWindowID: second.id)
        #expect(BrowserWorkspaceStore(sessionURL: file).restoredWindows == [second])
        #expect(try Data(contentsOf: store.sessionURL(for: second)) == otherSnapshot)
        #expect(try JSONDecoder().decode(BrowserSession.self, from: Data(contentsOf: store.sessionURL(for: first))).tabs.count == 2)
        secondModel.shutdown()
    }

    @Test @MainActor func anExplicitlyEmptyWorkspaceDoesNotResurrectLegacyWindows() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = BrowserWorkspaceStore(sessionURL: file)
        try store.save(windows: [], activeWindowID: UUID())
        let restored = BrowserWorkspaceStore(sessionURL: file)
        #expect(restored.restoredWindows.isEmpty)
        #expect(restored.restoredActiveWindowID == nil)
    }

    @Test @MainActor func unreadableWorkspaceIsPreservedBeforeRecovery() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let manifest = file.deletingPathExtension().appendingPathExtension("windows.json")
        let original = Data("{incomplete window manifest".utf8)
        try original.write(to: manifest)
        let store = BrowserWorkspaceStore(sessionURL: file)
        #expect(store.restoredWindows.first?.usesLegacySession == true)
        try store.save(windows: store.restoredWindows, activeWindowID: store.restoredActiveWindowID)
        let files = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let backup = try #require(files.first { $0.lastPathComponent.contains("preserved-") })
        #expect(try Data(contentsOf: backup) == original)
    }

    @Test @MainActor func rejectsDuplicateWindowAndLegacySessionReferences() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let id = UUID()
        let duplicateLegacy = UUID()
        let second = UUID()
        let object: [String: Any] = ["version": 1, "windows": [
            ["id": id.uuidString, "usesLegacySession": true],
            ["id": id.uuidString, "usesLegacySession": false],
            ["id": duplicateLegacy.uuidString, "usesLegacySession": true],
            ["id": second.uuidString, "usesLegacySession": false]
        ], "activeWindowID": duplicateLegacy.uuidString]
        try JSONSerialization.data(withJSONObject: object).write(to: file.deletingPathExtension().appendingPathExtension("windows.json"))
        let restored = BrowserWorkspaceStore(sessionURL: file)
        #expect(restored.restoredWindows.map(\.id) == [id, second])
        #expect(restored.restoredActiveWindowID == second)
    }
}
