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
        }
        probe.removeFromSuperview()
        #expect(reference.screenPoint(forSidebarPoint: .zero) == nil)
    }

    private final class FlippedDragProbe: NSView {
        override var isFlipped: Bool { true }
    }
}
