import AppKit
import Foundation
import Testing
@testable import NousBrowser

@Suite("Independent sidebar presentation and visibility", .serialized)
@MainActor
struct BrowserSidebarStateTests {
    @MainActor private struct Fixture {
        let directory: URL
        let sessionURL: URL
        let model: BrowserModel

        func cleanUp() {
            model.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.json")
        let model = BrowserModel(sessionURL: file, restoreSession: false, loadSelectedTab: false, startWithBlankTab: true)
        return Fixture(directory: directory, sessionURL: file, model: model)
    }

    @Test func compactThenFullHideRestoresCompactAndKeepsThePreferredWidth() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let originalTab = try #require(model.selectedTab)
        let originalWebView = originalTab.webView
        model.resizeSidebar(to: 327)

        model.toggleSidebar()
        #expect(model.isSidebarVisible && model.isSidebarCompact)
        model.toggleSidebarHidden()
        #expect(!model.isSidebarVisible && model.isSidebarCompact)
        model.toggleSidebarHidden()
        #expect(model.isSidebarVisible && model.isSidebarCompact)
        model.toggleSidebar()
        #expect(model.isSidebarVisible && !model.isSidebarCompact)

        #expect(model.sidebarWidth == 327)
        #expect(model.selectedTab === originalTab)
        #expect(model.selectedTab?.webView === originalWebView)
        #expect(model.tabs.count == 1)
    }

    @Test func fullHideRestoresExpandedWithoutChangingItsWidth() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.resizeSidebar(to: 301)
        for _ in 0..<3 {
            model.toggleSidebarHidden()
            #expect(!model.isSidebarVisible && !model.isSidebarCompact)
            model.toggleSidebarHidden()
            #expect(model.isSidebarVisible && !model.isSidebarCompact)
        }
        #expect(model.sidebarWidth == 301)
    }

    @Test(arguments: [false, true])
    func expandCommandFromFullyHiddenRevealsTheExpandedList(wasCompact: Bool) throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        if wasCompact { model.toggleSidebar() }
        model.toggleSidebarHidden()

        model.toggleSidebar()
        #expect(model.isSidebarVisible && !model.isSidebarCompact)
        model.toggleSidebarHidden()
        model.toggleSidebarHidden()
        #expect(model.isSidebarVisible && !model.isSidebarCompact)
    }

    @Test(arguments: [false, true], [false, true])
    func allPresentationCombinationsSurviveSessionRestoration(visible: Bool, compact: Bool) throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.resizeSidebar(to: 364)
        model.isSidebarVisible = visible
        model.isSidebarCompact = compact
        let expectedTabID = model.selectedTabID
        model.persistSession()

        let saved = try JSONDecoder().decode(BrowserSession.self, from: Data(contentsOf: fixture.sessionURL))
        #expect(saved.isSidebarVisible == visible)
        #expect(saved.isSidebarCompact == compact)
        #expect(saved.sidebarWidth == 364)
        let restored = BrowserModel(sessionURL: fixture.sessionURL, loadSelectedTab: false)
        defer { restored.shutdown() }
        #expect(restored.isSidebarVisible == visible)
        #expect(restored.isSidebarCompact == compact)
        #expect(restored.sidebarWidth == 364)
        #expect(restored.selectedTabID == expectedTabID)
        if !visible {
            restored.toggleSidebarHidden()
            #expect(restored.isSidebarVisible)
            #expect(restored.isSidebarCompact == compact)
        }
    }

    @Test(arguments: [false, true])
    func legacySessionsKeepTheirVisibilityAndDefaultToExpanded(visible: Bool) throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let tabID = UUID()
        let legacy: [String: Any] = [
            "tabs": [["id": tabID.uuidString, "title": "Legacy tab"]],
            "selectedTabID": tabID.uuidString,
            "isSidebarVisible": visible,
            "sidebarWidth": 289
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: fixture.sessionURL)
        let restored = BrowserModel(sessionURL: fixture.sessionURL, loadSelectedTab: false)
        defer { restored.shutdown() }
        #expect(restored.isSidebarVisible == visible)
        #expect(!restored.isSidebarCompact)
        #expect(restored.sidebarWidth == 289)
        #expect(restored.selectedTabID == tabID)
    }

    @Test func invalidCompactPreferenceDoesNotDiscardTheSession() throws {
        let tabID = UUID()
        let json: [String: Any] = [
            "tabs": [["id": tabID.uuidString, "title": "Keep this tab"]],
            "selectedTabID": tabID.uuidString,
            "isSidebarVisible": false,
            "sidebarWidth": 312,
            "isSidebarCompact": "invalid"
        ]
        let decoded = try JSONDecoder().decode(BrowserSession.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.tabs.map(\.id) == [tabID])
        #expect(decoded.selectedTabID == tabID)
        #expect(!decoded.isSidebarVisible && !decoded.isSidebarCompact)
        #expect(decoded.sidebarWidth == 312)
    }

    @Test(arguments: [false, true])
    func detachingATabPreservesTheSourcePresentationWithoutChangingAnotherWindow(hidden: Bool) throws {
        _ = NSApplication.shared
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        fixture.model.persistSession()
        let defaultsDomain = "NousSidebarStateTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        defer { defaults.removePersistentDomain(forName: defaultsDomain) }
        let manager = BrowserWindowManager(workspace: BrowserWorkspaceStore(sessionURL: fixture.sessionURL),
            appearance: BrowserAppearanceSettings(defaults: defaults), preferences: BrowserPreferences(defaults: defaults),
            showsWindows: false, startsHibernationMonitors: false)
        defer {
            manager.prepareForTermination()
            manager.windows.forEach { $0.window.close() }
        }
        manager.restoreWindows()
        let source = try #require(manager.activeContext)
        let sourceModel = source.controller.model
        sourceModel.newTab()
        sourceModel.resizeSidebar(to: 318)
        sourceModel.toggleSidebar()
        if hidden { sourceModel.toggleSidebarHidden() }
        let existing = try #require(manager.newWindow())
        existing.controller.model.resizeSidebar(to: 380)
        let tab = try #require(sourceModel.selectedTab)
        let webView = tab.webView

        let detached = try #require(manager.moveTabToNewWindow(tab.id, from: source.session.id))
        let destinationModel = detached.controller.model
        #expect(destinationModel.selectedTab === tab)
        #expect(destinationModel.selectedTab?.webView === webView)
        #expect(destinationModel.sidebarWidth == 318)
        #expect(destinationModel.isSidebarCompact)
        #expect(destinationModel.isSidebarVisible == !hidden)
        #expect(sourceModel.isSidebarCompact && sourceModel.isSidebarVisible == !hidden)
        #expect(!existing.controller.model.isSidebarCompact && existing.controller.model.isSidebarVisible)
        #expect(existing.controller.model.sidebarWidth == 380)

        let workspace = BrowserWorkspaceStore(sessionURL: fixture.sessionURL)
        let restored = BrowserModel(sessionURL: workspace.sessionURL(for: detached.session), loadSelectedTab: false)
        defer { restored.shutdown() }
        #expect(restored.isSidebarCompact && restored.isSidebarVisible == !hidden)
        #expect(restored.sidebarWidth == 318)
        if hidden { restored.toggleSidebarHidden() }
        #expect(restored.isSidebarVisible && restored.isSidebarCompact)
    }
}
