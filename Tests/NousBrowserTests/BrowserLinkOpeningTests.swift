import AppKit
import Foundation
import Testing
import WebKit
@testable import NousBrowser

@Suite("Opening webpage links in tabs and windows", .serialized)
@MainActor
struct BrowserLinkOpeningTests {
    @Test func newTabFollowsItsUnselectedSourceWithoutReplacingAnyExistingPage() throws {
        let fixture = try modelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let originalTabs = model.tabs
        let originalViews = originalTabs.map(\.webView)
        let source = originalTabs[1]
        #expect(model.selectedTabID == originalTabs[3].id)
        #expect(source.webView.url == nil)

        let opened = try #require(model.openLinkInNewTab(fixture.targetURL, after: source.id))

        let expectedOrder = [originalTabs[0].id, source.id, opened.id, originalTabs[2].id, originalTabs[3].id]
        #expect(model.tabs.map(\.id) == expectedOrder)
        #expect(model.selectedTab === opened)
        #expect(opened.url == fixture.targetURL)
        #expect(!opened.isPinned)
        for (index, tab) in originalTabs.enumerated() {
            #expect(model.tabs.contains { $0 === tab })
            #expect(tab.webView === originalViews[index])
            #expect(tab.url == fixture.pageURLs[index])
            #expect(tab.webView.url == nil)
            #expect(opened.webView !== tab.webView)
        }
        #expect(opened.webView.configuration.websiteDataStore === source.webView.configuration.websiteDataStore)
        let saved = try JSONDecoder().decode(BrowserSession.self, from: Data(contentsOf: fixture.sessionURL))
        #expect(saved.tabs.map(\.id) == expectedOrder)
        #expect(saved.selectedTabID == opened.id)
    }

    @Test func missingClosedAndUnsupportedSourcesDoNotCreateTabsOrRouteWindows() throws {
        let fixture = try modelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let closedID = model.tabs[1].id
        model.closeTab(closedID)
        let existingIDs = model.tabs.map(\.id)
        let selectedID = model.selectedTabID
        let existingSession = try Data(contentsOf: fixture.sessionURL)
        var windowRequests: [URL] = []
        model.onOpenLinkInNewWindow = { windowRequests.append($0) }
        let validSource = try #require(model.tabs.first?.id)

        #expect(model.openLinkInNewTab(fixture.targetURL, after: closedID) == nil)
        #expect(model.openLinkInNewTab(fixture.targetURL, after: UUID()) == nil)
        model.openLinkInNewWindow(fixture.targetURL, from: closedID)
        model.openLinkInNewWindow(fixture.targetURL, from: UUID())
        for input in ["javascript:alert(1)", "data:text/html,fixture", "ftp://fixture.example/",
                      "custom-fixture:open", fixture.directory.appendingPathComponent("not-html.txt").absoluteString] {
            let unsupported = try #require(URL(string: input))
            #expect(model.openLinkInNewTab(unsupported, after: validSource) == nil)
            model.openLinkInNewWindow(unsupported, from: validSource)
        }

        #expect(model.tabs.map(\.id) == existingIDs)
        #expect(model.selectedTabID == selectedID)
        #expect(windowRequests.isEmpty)
        #expect(try Data(contentsOf: fixture.sessionURL) == existingSession)
    }

    @Test func linksFromAPinnedSourceStartTheNormalGroupAndKeepAllPinsTogether() throws {
        let fixture = try modelFixture(pinnedCount: 2)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let original = model.tabs
        let source = original[0]
        let opened = try #require(model.openLinkInNewTab(fixture.targetURL, after: source.id))

        #expect(model.tabs.map(\.id) == [original[0].id, original[1].id, opened.id, original[2].id, original[3].id])
        #expect(model.tabs.map(\.isPinned) == [true, true, false, false, false])
        #expect(model.tabs[0] === original[0] && model.tabs[1] === original[1])
        #expect(source.url == fixture.pageURLs[0])
        #expect(source.webView.url == nil)
        #expect(model.selectedTab === opened)
    }

    @Test func aModelsNewWindowRequestCreatesOneTargetTabAndLeavesBothExistingWindowsIntact() throws {
        let fixture = try windowFixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.restoreWindows()
        let sourceWindow = try #require(manager.activeContext)
        let model = sourceWindow.controller.model
        let source = try #require(model.tabs.first)
        let sourceIDs = model.tabs.map(\.id)
        let selectedID = model.selectedTabID
        let sourceView = source.webView
        let peer = try #require(manager.newWindow())
        let peerTab = try #require(peer.controller.model.selectedTab)
        #expect(manager.activeContext === peer)

        model.openLinkInNewWindow(fixture.targetURL, from: source.id)

        let destination = try #require(manager.activeContext)
        let target = try #require(destination.controller.model.selectedTab)
        #expect(manager.windows.count == 3)
        #expect(destination !== sourceWindow && destination !== peer)
        #expect(destination.controller.model !== model)
        #expect(destination.controller.model.tabs.count == 1)
        #expect(target.url == fixture.targetURL)
        #expect(target.id != source.id && target.webView !== sourceView)
        #expect(!destination.controller.isAddressPresented)
        #expect(target.webView.configuration.websiteDataStore === sourceView.configuration.websiteDataStore)
        #expect(model.tabs.map(\.id) == sourceIDs)
        #expect(model.selectedTabID == selectedID)
        #expect(source.url == fixture.pageURLs[0])
        #expect(source.webView === sourceView)
        #expect(peer.controller.model.tabs.count == 1)
        #expect(peer.controller.model.selectedTab === peerTab)
        #expect(peerTab.url == nil)
        let workspace = BrowserWorkspaceStore(sessionURL: fixture.sessionURL)
        #expect(workspace.restoredWindows == manager.windows.map(\.session))
        #expect(workspace.restoredActiveWindowID == destination.session.id)
        let saved = try JSONDecoder().decode(BrowserSession.self,
                                             from: Data(contentsOf: workspace.sessionURL(for: destination.session)))
        #expect(saved.tabs.count == 1 && saved.tabs[0].url == fixture.targetURL)
    }

    @Test func lateRequestsFromAClosedTabOrWindowCannotOpenAnotherWindow() throws {
        let fixture = try windowFixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.restoreWindows()
        let source = try #require(manager.activeContext)
        let model = source.controller.model
        let closedTabID = try #require(model.tabs.first?.id)
        model.closeTab(closedTabID)
        let survivingTabID = try #require(model.selectedTabID)
        let peer = try #require(manager.newWindow())
        let peerIDs = peer.controller.model.tabs.map(\.id)
        let windowsBefore = manager.windows.map(\.session)

        model.openLinkInNewWindow(fixture.targetURL, from: closedTabID)
        model.openLinkInNewWindow(try #require(URL(string: "javascript:alert(1)")), from: survivingTabID)
        #expect(manager.windows.map(\.session) == windowsBefore)
        #expect(manager.activeContext === peer)

        manager.closeWindow(source.session.id)
        #expect(manager.windows.count == 1)
        #expect(model.onOpenLinkInNewWindow == nil)
        model.openLinkInNewWindow(fixture.targetURL, from: survivingTabID)
        #expect(manager.openLinkInNewWindow(fixture.targetURL, from: source.session.id) == nil)
        #expect(manager.windows.count == 1)
        #expect(manager.activeContext === peer)
        #expect(peer.controller.model.tabs.map(\.id) == peerIDs)
        #expect(BrowserWorkspaceStore(sessionURL: fixture.sessionURL).restoredWindows == [peer.session])
    }

    @MainActor private struct ModelFixture {
        let directory: URL
        let sessionURL: URL
        let pageURLs: [URL]
        let targetURL: URL
        let model: BrowserModel

        func cleanUp() {
            model.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func modelFixture(pinnedCount: Int = 0) throws -> ModelFixture {
        let files = try makeFiles(tabCount: 4)
        let records = files.pageURLs.enumerated().map { index, url in
            BrowserSession.Tab(id: UUID(), title: "Local source \(index)", url: url, isPinned: index < pinnedCount)
        }
        let session = BrowserSession(tabs: records, selectedTabID: records.last?.id, isSidebarVisible: true)
        try JSONEncoder().encode(session).write(to: files.sessionURL)
        let model = BrowserModel(sessionURL: files.sessionURL, loadSelectedTab: false)
        return ModelFixture(directory: files.directory, sessionURL: files.sessionURL,
                            pageURLs: files.pageURLs, targetURL: files.targetURL, model: model)
    }

    @MainActor private struct WindowFixture {
        let directory: URL
        let sessionURL: URL
        let pageURLs: [URL]
        let targetURL: URL
        let defaults: UserDefaults
        let defaultsDomain: String
        let manager: BrowserWindowManager

        func cleanUp() {
            manager.prepareForTermination()
            manager.windows.forEach { $0.window.close() }
            defaults.removePersistentDomain(forName: defaultsDomain)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func windowFixture() throws -> WindowFixture {
        _ = NSApplication.shared
        let files = try makeFiles(tabCount: 2)
        let records = files.pageURLs.enumerated().map { index, url in
            BrowserSession.Tab(id: UUID(), title: "Local window source \(index)", url: url)
        }
        try JSONEncoder().encode(BrowserSession(tabs: records, selectedTabID: records.last?.id,
                                                isSidebarVisible: true)).write(to: files.sessionURL)
        let domain = "NousBrowserLinkOpeningTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        let manager = BrowserWindowManager(workspace: BrowserWorkspaceStore(sessionURL: files.sessionURL),
                                           appearance: BrowserAppearanceSettings(defaults: defaults),
                                           preferences: BrowserPreferences(defaults: defaults),
                                           showsWindows: false, startsHibernationMonitors: false)
        return WindowFixture(directory: files.directory, sessionURL: files.sessionURL,
                             pageURLs: files.pageURLs, targetURL: files.targetURL,
                             defaults: defaults, defaultsDomain: domain, manager: manager)
    }

    private func makeFiles(tabCount: Int) throws -> (directory: URL, sessionURL: URL, pageURLs: [URL], targetURL: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NousBrowserLinkOpening-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pages = (0..<tabCount).map { directory.appendingPathComponent("source-\($0).html") }
        let target = directory.appendingPathComponent("target.html")
        for (index, url) in (pages + [target]).enumerated() {
            try Data("<!doctype html><title>Local link fixture \(index)</title><p>Synthetic fixture</p>".utf8).write(to: url)
        }
        return (directory, directory.appendingPathComponent("session.json"), pages, target)
    }
}
