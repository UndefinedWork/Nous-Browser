import AppKit
import Foundation
import Testing
import WebKit
@testable import NousBrowser

@Suite("Live tabs transfer between windows", .serialized)
@MainActor
struct BrowserTabTransferTests {
    @MainActor private struct Fixture {
        let directory: URL
        let sessionURL: URL
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

    private func fixture(tabCount: Int) throws -> Fixture {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessionURL = directory.appendingPathComponent("session.json")
        let tabs = (0..<tabCount).map {
            BrowserSession.Tab(id: UUID(), title: "Synthetic tab \($0 + 1)", url: nil)
        }
        let session = BrowserSession(tabs: tabs, selectedTabID: tabs.first?.id, isSidebarVisible: true)
        try JSONEncoder().encode(session).write(to: sessionURL)
        let defaultsDomain = "NousBrowserTransferTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        let manager = BrowserWindowManager(workspace: BrowserWorkspaceStore(sessionURL: sessionURL),
                                           appearance: BrowserAppearanceSettings(defaults: defaults),
                                           preferences: BrowserPreferences(defaults: defaults),
                                           showsWindows: false, startsHibernationMonitors: false)
        manager.restoreWindows()
        return Fixture(directory: directory, sessionURL: sessionURL, defaults: defaults,
                       defaultsDomain: defaultsDomain, manager: manager)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<160 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition(), "The local transfer fixture did not finish its navigation or callback.")
    }

    private func writePage(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name + ".html")
        let html = """
        <!doctype html><meta charset="utf-8"><title>\(name)</title>
        <input id="draft" value="Initial synthetic draft">
        <script>window.transferMarker = 'new-document';</script><p>Local transfer fixture</p>
        """
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func loadTwoPages(in tab: BrowserTab, directory: URL) async throws -> (first: URL, second: URL) {
        let first = try writePage("First transfer page", in: directory)
        let second = try writePage("Second transfer page", in: directory)
        tab.load(first)
        try await waitUntil { tab.webView.url == first && !tab.webView.isLoading }
        tab.load(second)
        try await waitUntil {
            tab.webView.url == second && !tab.webView.isLoading
                && tab.webView.backForwardList.backItem?.url == first
        }
        _ = try await tab.webView.evaluateJavaScript("""
        window.transferMarker = 'kept-document';
        document.getElementById('draft').value = 'Kept synthetic draft';
        true;
        """)
        return (first, second)
    }

    private func documentState(_ view: WKWebView) async throws -> String {
        let value = try await view.evaluateJavaScript("""
        JSON.stringify({marker: window.transferMarker, draft: document.getElementById('draft').value})
        """)
        return try #require(value as? String)
    }

    private func destination(in manager: BrowserWindowManager, tabCount: Int) throws -> BrowserWindowContext {
        let context = try #require(manager.newWindow())
        while context.controller.model.tabs.count < tabCount { context.controller.model.newTab() }
        return context
    }

    private func savedSession(for context: BrowserWindowContext, in fixture: Fixture) throws -> BrowserSession {
        let workspace = BrowserWorkspaceStore(sessionURL: fixture.sessionURL)
        return try JSONDecoder().decode(BrowserSession.self,
            from: Data(contentsOf: workspace.sessionURL(for: context.session)))
    }

    @Test(arguments: [-2, 0, 2, 4, Int.max])
    func existingWindowInsertionPreservesItsTabsAndSelectsTheIncomingPage(slot: Int) throws {
        let fixture = try fixture(tabCount: 3)
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let source = try #require(manager.activeContext)
        let moving = source.controller.model.tabs[0]
        let remaining = source.controller.model.tabs.dropFirst().map(\.id)
        let target = try destination(in: manager, tabCount: 4)
        let previousTabs = target.controller.model.tabs
        var expected = previousTabs.map(\.id)
        expected.insert(moving.id, at: max(0, min(expected.count, slot)))
        #expect(target.controller.isAddressPresented)

        #expect(manager.moveTab(moving.id, from: source.session.id, to: target.session.id, at: slot))
        #expect(manager.windows.count == 2)
        #expect(manager.activeContext === target)
        #expect(target.controller.model.tabs.map(\.id) == expected)
        #expect(target.controller.model.tabs.filter { $0.id != moving.id }.map(\.id) == previousTabs.map(\.id))
        #expect(previousTabs.allSatisfy { old in target.controller.model.tabs.contains { $0 === old } })
        #expect(target.controller.model.selectedTab === moving)
        #expect(source.controller.model.tabs.map(\.id) == remaining)
        #expect(source.controller.model.selectedTabID == remaining.first)
        #expect(!source.controller.model.canRestoreClosedTab)
        #expect(!target.controller.isAddressPresented)
        #expect(!moving.isPinned)
    }

    @Test(arguments: [false, true], [-3, 1, Int.max])
    func existingWindowInsertionClampsToTheIncomingPinGroup(pinned: Bool, slot: Int) throws {
        let fixture = try fixture(tabCount: 2)
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let source = try #require(manager.activeContext)
        let moving = try #require(source.controller.model.selectedTab)
        if pinned { source.controller.model.togglePin(moving.id) }
        let target = try destination(in: manager, tabCount: 4)
        let firstPin = target.controller.model.tabs[0].id
        let secondPin = target.controller.model.tabs[1].id
        target.controller.model.togglePin(firstPin)
        target.controller.model.togglePin(secondPin)
        let previous = target.controller.model.tabs.map(\.id)
        let expectedSlot = pinned ? max(0, min(2, slot)) : max(2, min(previous.count, slot))
        var expected = previous
        expected.insert(moving.id, at: expectedSlot)

        #expect(manager.moveTab(moving.id, from: source.session.id, to: target.session.id, at: slot))
        #expect(target.controller.model.tabs.map(\.id) == expected)
        #expect(moving.isPinned == pinned)
        #expect(target.controller.model.tabs.prefix(pinned ? 3 : 2).allSatisfy { $0.isPinned })
        #expect(target.controller.model.tabs.dropFirst(pinned ? 3 : 2).allSatisfy { !$0.isPinned })
        #expect(target.controller.model.selectedTab === moving)
        let saved = try savedSession(for: target, in: fixture)
        #expect(saved.tabs.map(\.id) == expected)
        #expect(saved.tabs.first { $0.id == moving.id }?.isPinned == pinned)
    }

    @Test func backgroundMoveToAnExistingWindowPersistsBothSidesAndKeepsTheirClosedTabHistory() throws {
        let fixture = try fixture(tabCount: 4)
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let source = try #require(manager.activeContext)
        let sourceModel = source.controller.model
        let selected = try #require(sourceModel.selectedTab)
        let moving = sourceModel.tabs[1]
        let sourceClosed = sourceModel.tabs[3]
        sourceModel.closeTab(sourceClosed.id)
        let sourceRemaining = sourceModel.tabs.filter { $0.id != moving.id }.map(\.id)
        sourceModel.resizeSidebar(to: 300)
        let target = try destination(in: manager, tabCount: 3)
        let targetModel = target.controller.model
        let targetClosed = targetModel.tabs[2]
        targetModel.closeTab(targetClosed.id)
        targetModel.resizeSidebar(to: 367)
        targetModel.isSidebarVisible = false
        let targetIDs = targetModel.tabs.map(\.id)
        source.controller.passwords.presentImport()
        target.controller.passwords.presentImport()
        #expect(manager.activeContext === target)

        #expect(manager.moveTab(moving.id, from: source.session.id, to: target.session.id, at: 1))
        #expect(sourceModel.selectedTab === selected)
        #expect(sourceModel.tabs.map(\.id) == sourceRemaining)
        #expect(!sourceModel.tabs.contains { $0 === moving })
        #expect(source.controller.passwords.isPresented)
        #expect(!target.controller.passwords.isPresented)
        #expect(targetModel.tabs.map(\.id) == [targetIDs[0], moving.id, targetIDs[1]])
        #expect(targetModel.selectedTab === moving)
        #expect(sourceModel.sidebarWidth == 300)
        #expect(targetModel.sidebarWidth == 367 && !targetModel.isSidebarVisible)
        #expect(sourceModel.canRestoreClosedTab && targetModel.canRestoreClosedTab)
        let sourceSaved = try savedSession(for: source, in: fixture)
        let targetSaved = try savedSession(for: target, in: fixture)
        #expect(sourceSaved.tabs.map(\.id) == sourceModel.tabs.map(\.id))
        #expect(sourceSaved.selectedTabID == selected.id)
        #expect(targetSaved.tabs.map(\.id) == targetModel.tabs.map(\.id))
        #expect(targetSaved.selectedTabID == moving.id)
        #expect(targetSaved.sidebarWidth == 367 && !targetSaved.isSidebarVisible)
        let workspace = BrowserWorkspaceStore(sessionURL: fixture.sessionURL)
        #expect(Set(workspace.restoredWindows.map(\.id)) == Set([source.session.id, target.session.id]))
        #expect(workspace.restoredActiveWindowID == target.session.id)

        sourceModel.restoreClosedTab()
        targetModel.restoreClosedTab()
        #expect(sourceModel.selectedTabID == sourceClosed.id)
        #expect(targetModel.selectedTabID == targetClosed.id)
        #expect(!sourceModel.canRestoreClosedTab && !targetModel.canRestoreClosedTab)
        #expect(targetModel.tabs.contains { $0 === moving })
        #expect(!sourceModel.tabs.contains { $0 === moving })
    }

    @Test func movingTheLastTabIntoAnExistingWindowClosesOnlyItsFormerWindow() async throws {
        let fixture = try fixture(tabCount: 1)
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let source = try #require(manager.activeContext)
        let moving = try #require(source.controller.model.selectedTab)
        _ = try await loadTwoPages(in: moving, directory: fixture.directory)
        let view = moving.webView
        let before = try await documentState(view)
        let target = try destination(in: manager, tabCount: 2)
        let targetIDs = target.controller.model.tabs.map(\.id)

        #expect(manager.moveTab(moving.id, from: source.session.id, to: target.session.id, at: 1))
        #expect(manager.windows.count == 1 && manager.windows.first === target)
        #expect(manager.activeContext === target)
        #expect(source.controller.model.tabs.isEmpty && source.controller.model.selectedTabID == nil)
        #expect(source.window.contentView == nil && source.controller.model.onLastTabClosed == nil)
        #expect(target.controller.model.tabs.map(\.id) == [targetIDs[0], moving.id, targetIDs[1]])
        #expect(target.controller.model.selectedTab === moving)
        #expect(moving.webView === view)
        #expect(view.navigationDelegate === moving && view.uiDelegate === moving)
        #expect(try await documentState(view) == before)
        let workspace = BrowserWorkspaceStore(sessionURL: fixture.sessionURL)
        #expect(workspace.restoredWindows == [target.session])
        let saved = try savedSession(for: target, in: fixture)
        #expect(saved.tabs.map(\.id) == target.controller.model.tabs.map(\.id))
        #expect(saved.selectedTabID == moving.id)
    }

    @Test func existingWindowMovePreservesTheLivePageAndMovesNativeCallbacksWithoutAStaleDeckReclaim() async throws {
        let fixture = try fixture(tabCount: 2)
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let source = try #require(manager.activeContext)
        let sourceModel = source.controller.model
        let moving = try #require(sourceModel.selectedTab)
        let urls = try await loadTwoPages(in: moving, directory: fixture.directory)
        let view = moving.webView
        let store = view.configuration.websiteDataStore
        view.pageZoom = 1.75
        let before = try await documentState(view)
        // Supply both native decks directly so a delayed SwiftUI rendering in
        // a hidden test window cannot independently host the same page.
        source.window.contentView = nil
        let sourceSnapshot = sourceModel.tabs
        let sourceDeck = WebViewDeckView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        sourceDeck.show(sourceSnapshot, selectedID: moving.id, owner: sourceModel)
        #expect(view.superview === sourceDeck)
        let target = try destination(in: manager, tabCount: 2)
        target.window.contentView = nil
        let targetModel = target.controller.model
        let targetDeck = WebViewDeckView(frame: sourceDeck.frame)
        targetDeck.show(targetModel.tabs, selectedID: targetModel.selectedTabID, owner: targetModel)

        // Synthetic detection metadata exercises the native controller's tab
        // ownership only; no real credential or authentication is requested.
        let formURL = URL(string: "https://synthetic.example.test/login")!
        let candidate = BrowserPasswordAutofill.Candidate(token: UUID().uuidString, frameURL: formURL,
            origin: try #require(BrowserPasswordAutofill.Origin(url: formURL)), fieldTypes: ["email", "password"])
        moving.passwordCandidate = candidate
        source.controller.passwords.presentFill()
        target.controller.passwords.presentImport()
        #expect(source.controller.passwords.canFill)
        var sourceTitleUpdates = 0
        var targetTitleUpdates: [String] = []
        var sourceVisits: [URL] = []
        var targetVisits: [URL] = []
        sourceModel.onPageTitleChanged = { _, _ in sourceTitleUpdates += 1 }
        targetModel.onPageTitleChanged = { _, title in targetTitleUpdates.append(title) }
        sourceModel.onVisit = { url, _ in sourceVisits.append(url) }
        targetModel.onVisit = { url, _ in targetVisits.append(url) }

        #expect(manager.moveTab(moving.id, from: source.session.id, to: target.session.id, at: 1))
        targetDeck.show(targetModel.tabs, selectedID: moving.id, owner: targetModel)
        #expect(targetModel.selectedTab === moving && moving.webView === view)
        #expect(view.superview === targetDeck && !view.isHidden)
        #expect(view.configuration.websiteDataStore === store)
        #expect(view.navigationDelegate === moving && view.uiDelegate === moving)
        #expect(view.pageZoom == 1.75)
        #expect(view.url == urls.second && view.backForwardList.backItem?.url == urls.first)
        #expect(try await documentState(view) == before)
        #expect(moving.passwordCandidate == candidate)
        #expect(!source.controller.passwords.isPresented && !target.controller.passwords.isPresented)
        #expect(!source.controller.passwords.canFill && target.controller.passwords.canFill)
        moving.passwordCandidate = nil
        #expect(!target.controller.passwords.canFill)

        sourceDeck.show(sourceSnapshot, selectedID: moving.id, owner: sourceModel)
        #expect(view.superview === targetDeck)
        _ = try await view.evaluateJavaScript("document.title = 'Moved existing-window title'; true;")
        try await waitUntil { targetTitleUpdates.contains("Moved existing-window title") }
        #expect(sourceTitleUpdates == 0)
        sourceModel.shutdown()
        sourceDeck.show([], selectedID: nil, owner: sourceModel)
        #expect(view.superview === targetDeck)
        #expect(view.navigationDelegate === moving && view.uiDelegate === moving)
        #expect(try await documentState(view) == before)
        let next = try writePage("After existing-window transfer", in: fixture.directory)
        moving.load(next)
        try await waitUntil { targetVisits.contains(next) && !view.isLoading }
        #expect(sourceVisits.isEmpty)
        #expect(targetModel.selectedTab === moving)
        #expect(view.pageZoom == 1.75)
    }

    @Test func invalidExistingWindowTransfersLeaveBothWindowsAndTheirViewsUnchanged() throws {
        let fixture = try fixture(tabCount: 2)
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let source = try #require(manager.activeContext)
        let target = try destination(in: manager, tabCount: 2)
        let sourceTabs = source.controller.model.tabs
        let targetTabs = target.controller.model.tabs
        let sourceViews = sourceTabs.map(\.webView)
        let targetViews = targetTabs.map(\.webView)
        let sourceSelected = source.controller.model.selectedTabID
        let targetSelected = target.controller.model.selectedTabID
        let active = manager.activeContext
        let moving = sourceTabs[0]

        #expect(!manager.moveTab(UUID(), from: source.session.id, to: target.session.id, at: 0))
        #expect(!manager.moveTab(moving.id, from: UUID(), to: target.session.id, at: 0))
        #expect(!manager.moveTab(moving.id, from: source.session.id, to: UUID(), at: 0))
        #expect(!manager.moveTab(moving.id, from: source.session.id, to: source.session.id, at: 1))
        #expect(!manager.moveTab(targetTabs[0].id, from: source.session.id, to: target.session.id, at: 0))
        #expect(manager.windows.count == 2 && manager.activeContext === active)
        #expect(source.controller.model.tabs.map(\.id) == sourceTabs.map(\.id))
        #expect(target.controller.model.tabs.map(\.id) == targetTabs.map(\.id))
        #expect(zip(source.controller.model.tabs, sourceTabs).allSatisfy { $0.0 === $0.1 })
        #expect(zip(target.controller.model.tabs, targetTabs).allSatisfy { $0.0 === $0.1 })
        #expect(zip(source.controller.model.tabs, sourceViews).allSatisfy { $0.0.webView === $0.1 })
        #expect(zip(target.controller.model.tabs, targetViews).allSatisfy { $0.0.webView === $0.1 })
        #expect(source.controller.model.selectedTabID == sourceSelected)
        #expect(target.controller.model.selectedTabID == targetSelected)
        #expect(!source.controller.model.canRestoreClosedTab && !target.controller.model.canRestoreClosedTab)
        target.controller.model.shutdown()
        #expect(!manager.moveTab(moving.id, from: source.session.id, to: target.session.id, at: 0))
        #expect(source.controller.model.tabs.map(\.id) == sourceTabs.map(\.id))
        #expect(source.controller.model.selectedTabID == sourceSelected)
    }

    @Test func windowTitleUsesOnlyTheSelectedDisplayTitleAndTracksWebKitTitleChanges() async throws {
        let fixture = try fixture(tabCount: 2)
        defer { fixture.cleanUp() }
        let source = try #require(fixture.manager.activeContext)
        let model = source.controller.model
        let selected = try #require(model.selectedTab)
        let background = model.tabs[1]
        selected.title = "A stale blank-tab title"
        #expect(selected.displayTitle == L10n.string("New Tab"))
        #expect(source.window.title == selected.displayTitle)
        let selectedPage = try writePage("Selected page title", in: fixture.directory)
        selected.load(selectedPage)
        try await waitUntil { !selected.webView.isLoading && source.window.title == "Selected page title" }
        let peer = try destination(in: fixture.manager, tabCount: 1)
        let peerTitle = peer.window.title
        let backgroundPage = try writePage("Background page title", in: fixture.directory)
        background.load(backgroundPage)
        try await waitUntil { !background.webView.isLoading && background.title == "Background page title" }
        _ = try await background.webView.evaluateJavaScript("document.title = 'Asynchronous background title'; true;")
        try await waitUntil { background.title == "Asynchronous background title" }
        #expect(source.window.title == "Selected page title")
        #expect(peer.window.title == peerTitle)

        model.selectTab(background.id)
        try await waitUntil { source.window.title == "Asynchronous background title" }
        _ = try await background.webView.evaluateJavaScript("document.title = 'Asynchronous selected title'; true;")
        try await waitUntil { source.window.title == "Asynchronous selected title" }
        #expect(source.window.title == model.selectedTab?.displayTitle)
        #expect(peer.window.title == peerTitle)
        model.selectTab(selected.id)
        try await waitUntil { source.window.title == "Selected page title" }
        #expect(fixture.manager.activeContext === peer)
    }

    @Test func existingWindowTransferUpdatesBothWindowTitlesWithoutRetainingTheFormerSelection() async throws {
        let fixture = try fixture(tabCount: 2)
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let source = try #require(manager.activeContext)
        let moving = try #require(source.controller.model.selectedTab)
        moving.hasWebContent = true
        moving.title = "Incoming page title"
        let remaining = source.controller.model.tabs[1]
        remaining.hasWebContent = true
        remaining.title = "Remaining source title"
        let target = try destination(in: manager, tabCount: 1)
        let previousTarget = try #require(target.controller.model.selectedTab)
        previousTarget.hasWebContent = true
        previousTarget.title = "Previous target title"
        try await waitUntil { source.window.title == "Incoming page title" && target.window.title == "Previous target title" }

        #expect(manager.moveTab(moving.id, from: source.session.id, to: target.session.id, at: 0))
        try await waitUntil { source.window.title == "Remaining source title" && target.window.title == "Incoming page title" }
        moving.title = "Updated transferred title"
        previousTarget.title = "Updated background target title"
        try await waitUntil { target.window.title == "Updated transferred title" }
        #expect(source.window.title == "Remaining source title")
    }

    @Test func shuttingDownAWindowStopsQueuedAndFutureTitleObservation() async throws {
        let fixture = try fixture(tabCount: 1)
        defer { fixture.cleanUp() }
        let source = try #require(fixture.manager.activeContext)
        let tab = try #require(source.controller.model.selectedTab)
        tab.hasWebContent = true
        tab.title = "Title before shutdown"
        try await waitUntil { source.window.title == "Title before shutdown" }
        tab.title = "Queued title after shutdown"
        source.shutdown()
        for _ in 0..<4 { await Task.yield() }
        #expect(source.window.title == "Title before shutdown")
        tab.title = "Future title after shutdown"
        for _ in 0..<4 { await Task.yield() }
        #expect(source.window.title == "Title before shutdown")
    }

    @Test func movingALivePageKeepsItsViewDocumentHistoryZoomAndNewOwner() async throws {
        let fixture = try fixture(tabCount: 3)
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let source = try #require(manager.activeContext)
        let model = source.controller.model
        let tab = try #require(model.selectedTab)
        let remaining = model.tabs.dropFirst().map(\.id)
        model.togglePin(tab.id)
        let urls = try await loadTwoPages(in: tab, directory: fixture.directory)
        let view = tab.webView
        let websiteStore = view.configuration.websiteDataStore
        view.pageZoom = 1.5
        let before = try await documentState(view)

        let destination = try #require(manager.moveTabToNewWindow(tab.id, from: source.session.id))
        #expect(manager.windows.count == 2)
        #expect(destination.controller.model.tabs.map(\.id) == [tab.id])
        #expect(destination.controller.model.selectedTab === tab)
        #expect(destination.controller.model.selectedTab?.webView === view)
        #expect(tab.isPinned)
        #expect(model.tabs.map(\.id) == remaining)
        #expect(model.selectedTabID == remaining.first)
        #expect(!model.canRestoreClosedTab)
        #expect(view.navigationDelegate === tab && view.uiDelegate === tab)
        #expect(view.configuration.websiteDataStore === websiteStore)
        #expect(view.pageZoom == 1.5)
        #expect(view.url == urls.second)
        #expect(view.backForwardList.backItem?.url == urls.first)
        #expect(view.backForwardList.currentItem?.url == urls.second)
        #expect(try await documentState(view) == before)

        // Source cleanup must no longer own or invalidate this live page.
        model.shutdown()
        #expect(view.navigationDelegate === tab && view.uiDelegate === tab)
        #expect(try await documentState(view) == before)
        var destinationReceivedTitle = false
        destination.controller.model.onPageTitleChanged = { _, title in
            if title == "Transferred live title" { destinationReceivedTitle = true }
        }
        _ = try await view.evaluateJavaScript("document.title = 'Transferred live title'; true;")
        try await waitUntil { destinationReceivedTitle }
        #expect(view.pageZoom == 1.5)
    }

    @Test func movingTheOnlyTabClosesItsSourceAndLeavesTheTransferredPageAlive() async throws {
        let fixture = try fixture(tabCount: 1)
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let source = try #require(manager.activeContext)
        let tab = try #require(source.controller.model.selectedTab)
        _ = try await loadTwoPages(in: tab, directory: fixture.directory)
        let view = tab.webView
        let before = try await documentState(view)

        let destination = try #require(manager.moveTabToNewWindow(tab.id, from: source.session.id))
        #expect(manager.windows.count == 1)
        #expect(manager.windows.first === destination)
        #expect(manager.activeContext === destination)
        #expect(source.controller.model.tabs.isEmpty)
        #expect(source.controller.model.selectedTabID == nil)
        #expect(source.window.contentView == nil)
        #expect(source.controller.model.onLastTabClosed == nil)
        #expect(destination.controller.model.selectedTab === tab)
        #expect(tab.webView === view)
        #expect(view.navigationDelegate === tab && view.uiDelegate === tab)
        #expect(try await documentState(view) == before)

        let restored = BrowserWorkspaceStore(sessionURL: fixture.sessionURL)
        #expect(restored.restoredWindows == [destination.session])
        let session = try JSONDecoder().decode(BrowserSession.self,
            from: Data(contentsOf: restored.sessionURL(for: destination.session)))
        #expect(session.tabs.map(\.id) == [tab.id])
    }

    @Test func backgroundTransferTargetsItsOwningWindowAndPersistsBothLayoutsAndSessions() throws {
        let fixture = try fixture(tabCount: 3)
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let source = try #require(manager.activeContext)
        let sourceModel = source.controller.model
        let selected = try #require(sourceModel.selectedTab)
        let tab = sourceModel.tabs[1]
        sourceModel.resizeSidebar(to: 326)
        sourceModel.isSidebarVisible = false
        let peer = try #require(manager.newWindow())
        let peerIDs = peer.controller.model.tabs.map(\.id)
        let peerSelected = peer.controller.model.selectedTabID
        #expect(manager.activeContext === peer)

        let destination = try #require(manager.moveTabToNewWindow(tab.id, from: source.session.id))
        #expect(manager.windows.count == 3)
        #expect(sourceModel.selectedTab === selected)
        #expect(!sourceModel.tabs.contains { $0 === tab })
        #expect(!sourceModel.canRestoreClosedTab)
        #expect(peer.controller.model.tabs.map(\.id) == peerIDs)
        #expect(peer.controller.model.selectedTabID == peerSelected)
        #expect(destination.controller.model.selectedTab === tab)
        #expect(destination.controller.model.sidebarWidth == 326)
        #expect(!destination.controller.model.isSidebarVisible)
        #expect(destination.controller.preferences === source.controller.preferences)
        #expect(destination.controller.history === source.controller.history)

        let restored = BrowserWorkspaceStore(sessionURL: fixture.sessionURL)
        #expect(Set(restored.restoredWindows.map(\.id)) == Set([source.session.id, peer.session.id, destination.session.id]))
        #expect(restored.restoredActiveWindowID == destination.session.id)
        let savedSource = try JSONDecoder().decode(BrowserSession.self,
            from: Data(contentsOf: restored.sessionURL(for: source.session)))
        let savedDestination = try JSONDecoder().decode(BrowserSession.self,
            from: Data(contentsOf: restored.sessionURL(for: destination.session)))
        #expect(!savedSource.tabs.contains { $0.id == tab.id })
        #expect(savedSource.selectedTabID == selected.id)
        #expect(savedDestination.tabs.map(\.id) == [tab.id])
        #expect(savedDestination.selectedTabID == tab.id)
        #expect(savedDestination.sidebarWidth == 326 && !savedDestination.isSidebarVisible)
    }

    @Test func transferDoesNotReplaceThePreviouslyClosedTabHistory() throws {
        let fixture = try fixture(tabCount: 3)
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let source = try #require(manager.activeContext)
        let model = source.controller.model
        let moving = model.tabs[1]
        let previouslyClosed = model.tabs[2]
        model.closeTab(previouslyClosed.id)
        #expect(model.canRestoreClosedTab)
        let destination = try #require(manager.moveTabToNewWindow(moving.id, from: source.session.id))
        model.restoreClosedTab()
        #expect(model.selectedTabID == previouslyClosed.id)
        #expect(!model.tabs.contains { $0.id == moving.id })
        #expect(!model.canRestoreClosedTab)
        #expect(destination.controller.model.tabs.map(\.id) == [moving.id])
    }

    @Test func lateSourceDeckCleanupCannotDetachTheTransferredViewFromItsNewDeck() throws {
        let fixture = try fixture(tabCount: 2)
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let source = try #require(manager.activeContext)
        let tab = try #require(source.controller.model.selectedTab)
        tab.load(try writePage("Deck transfer", in: fixture.directory))
        let view = tab.webView
        let oldDeck = WebViewDeckView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let sourceSnapshot = source.controller.model.tabs
        oldDeck.show(sourceSnapshot, selectedID: tab.id, owner: source.controller.model)
        #expect(view.superview === oldDeck)

        let destination = try #require(manager.moveTabToNewWindow(tab.id, from: source.session.id))
        let newDeck = WebViewDeckView(frame: oldDeck.frame)
        newDeck.show(destination.controller.model.tabs, selectedID: tab.id, owner: destination.controller.model)
        #expect(view.superview === newDeck)
        #expect(!view.isHidden)
        // Simulate a delayed native update with the source's pre-transfer
        // snapshot. Ownership, not that stale array, decides which deck wins.
        oldDeck.show(sourceSnapshot, selectedID: tab.id, owner: source.controller.model)
        #expect(view.superview === newDeck)
        oldDeck.show(source.controller.model.tabs, selectedID: source.controller.model.selectedTabID,
                     owner: source.controller.model)
        source.controller.model.shutdown()
        oldDeck.show([], selectedID: nil, owner: source.controller.model)
        #expect(view.superview === newDeck)
        #expect(view.navigationDelegate === tab && view.uiDelegate === tab)
    }

    @Test func invalidTabOrWindowIDsDoNotCreateOrChangeWindows() throws {
        let fixture = try fixture(tabCount: 2)
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let source = try #require(manager.activeContext)
        let ids = source.controller.model.tabs.map(\.id)
        let views = source.controller.model.tabs.map(\.webView)
        let selected = source.controller.model.selectedTabID
        #expect(manager.moveTabToNewWindow(UUID(), from: source.session.id) == nil)
        #expect(manager.moveTabToNewWindow(ids[0], from: UUID()) == nil)
        #expect(manager.windows.count == 1)
        #expect(manager.windows.first === source)
        #expect(manager.activeContext === source)
        #expect(source.controller.model.tabs.map(\.id) == ids)
        #expect(source.controller.model.selectedTabID == selected)
        #expect(zip(source.controller.model.tabs, views).allSatisfy { $0.0.webView === $0.1 })
    }

    @Test func outsideDropRequiresCrossingTheWindowBufferOnEveryEdge() {
        let frame = NSRect(x: 100, y: 200, width: 900, height: 600)
        let insideOrBuffered: [NSPoint] = [
            NSPoint(x: 500, y: 500),
            NSPoint(x: 92.1, y: 500), NSPoint(x: 1007.9, y: 500),
            NSPoint(x: 500, y: 192.1), NSPoint(x: 500, y: 807.9)
        ]
        let outside: [NSPoint] = [
            NSPoint(x: 91.9, y: 500), NSPoint(x: 1008.1, y: 500),
            NSPoint(x: 500, y: 191.9), NSPoint(x: 500, y: 808.1)
        ]
        for point in insideOrBuffered { #expect(!SidebarTabDragGeometry.isOutsideWindow(point, frame: frame)) }
        for point in outside { #expect(SidebarTabDragGeometry.isOutsideWindow(point, frame: frame)) }
    }

    @Test func outsideDropUsesScreenCoordinatesIncludingNegativeDisplays() {
        let frame = NSRect(x: -1500, y: -400, width: 900, height: 600)
        #expect(!SidebarTabDragGeometry.isOutsideWindow(NSPoint(x: -1200, y: -100), frame: frame))
        #expect(!SidebarTabDragGeometry.isOutsideWindow(NSPoint(x: -1507, y: -100), frame: frame))
        #expect(!SidebarTabDragGeometry.isOutsideWindow(NSPoint(x: -593, y: -100), frame: frame))
        #expect(SidebarTabDragGeometry.isOutsideWindow(NSPoint(x: -1509, y: -100), frame: frame))
        #expect(SidebarTabDragGeometry.isOutsideWindow(NSPoint(x: -591, y: -100), frame: frame))
        #expect(SidebarTabDragGeometry.isOutsideWindow(NSPoint(x: -1200, y: -409), frame: frame))
        #expect(SidebarTabDragGeometry.isOutsideWindow(NSPoint(x: -1200, y: 209), frame: frame))
    }

    @Test func outsideDropRejectsNonfinitePointerCoordinates() {
        let frame = NSRect(x: -900, y: 0, width: 900, height: 600)
        for value in [CGFloat.nan, .infinity, -.infinity] {
            #expect(!SidebarTabDragGeometry.isOutsideWindow(NSPoint(x: value, y: 100), frame: frame))
            #expect(!SidebarTabDragGeometry.isOutsideWindow(NSPoint(x: -400, y: value), frame: frame))
        }
    }

    @Test(arguments: [false, true])
    func sidebarPointerMapsToScreenThroughItsOffsetView(flipped: Bool) throws {
        _ = NSApplication.shared
        let windowFrame = NSRect(x: -1400, y: -350, width: 900, height: 600)
        let window = NSWindow(contentRect: windowFrame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrame(windowFrame, display: false)
        defer {
            window.contentView = nil
            window.close()
        }
        let content = NSView(frame: NSRect(origin: .zero, size: windowFrame.size))
        window.contentView = content
        let probeFrame = NSRect(x: 35, y: 47, width: 243, height: 400)
        let probe: NSView = flipped ? FlippedDragProbe(frame: probeFrame) : NSView(frame: probeFrame)
        content.addSubview(probe)
        // A bounds origin is independent of the view's frame; conversion must
        // not assume the native sidebar probe starts at local coordinate zero.
        probe.bounds = NSRect(x: 11, y: 13, width: 243, height: 400)
        let reference = SidebarDragWindowReference()
        reference.window = window
        reference.view = probe
        reference.lastDragScreenPoint = NSPoint(x: 30_000, y: -20_000)
        #expect(window.frame == windowFrame)
        #expect(probe.isFlipped == flipped)

        // Both orientations describe the same SwiftUI top-left coordinates.
        // Expected values follow the fixed window/frame geometry, rather than
        // deriving a second answer with AppKit's conversion API under test.
        let points: [(CGPoint, NSPoint)] = [
            (.zero, NSPoint(x: -1365, y: 97)),
            (CGPoint(x: 20, y: 30), NSPoint(x: -1345, y: 67)),
            (CGPoint(x: 243, y: 400), NSPoint(x: -1122, y: -303)),
            (CGPoint(x: -100, y: -80), NSPoint(x: -1465, y: 177)),
            (CGPoint(x: 20, y: -200), NSPoint(x: -1345, y: 297))
        ]
        for (sidebarPoint, expected) in points {
            let screenPoint = try #require(reference.screenPoint(forSidebarPoint: sidebarPoint))
            #expect(abs(screenPoint.x - expected.x) < 0.001)
            #expect(abs(screenPoint.y - expected.y) < 0.001)
            let roundTrip = try #require(reference.sidebarPoint(forScreenPoint: screenPoint))
            #expect(abs(roundTrip.x - sidebarPoint.x) < 0.001)
            #expect(abs(roundTrip.y - sidebarPoint.y) < 0.001)
        }
        probe.removeFromSuperview()
        #expect(reference.screenPoint(forSidebarPoint: .zero) == nil)
        #expect(reference.sidebarPoint(forScreenPoint: .zero) == nil)
    }

    private final class FlippedDragProbe: NSView {
        override var isFlipped: Bool { true }
    }
}
