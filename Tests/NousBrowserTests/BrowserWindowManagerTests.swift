import AppKit
import Foundation
import Testing
@testable import NousBrowser

@Suite("Independent browser windows", .serialized)
@MainActor
struct BrowserWindowManagerTests {
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

    private func fixture(restoringBlankWindow: Bool = true) throws -> Fixture {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessionURL = directory.appendingPathComponent("session.json")
        if restoringBlankWindow {
            let tab = BrowserSession.Tab(id: UUID(), title: "Fixture", url: nil)
            let session = BrowserSession(tabs: [tab], selectedTabID: tab.id, isSidebarVisible: true)
            try JSONEncoder().encode(session).write(to: sessionURL)
        }
        let defaultsDomain = "NousBrowserWindowTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsDomain)!
        let manager = BrowserWindowManager(workspace: BrowserWorkspaceStore(sessionURL: sessionURL),
                                           appearance: BrowserAppearanceSettings(defaults: defaults),
                                           preferences: BrowserPreferences(defaults: defaults),
                                           showsWindows: false, startsHibernationMonitors: false)
        return Fixture(directory: directory, sessionURL: sessionURL, defaults: defaults,
                       defaultsDomain: defaultsDomain, manager: manager)
    }

    @Test func closingNewTabAlsoDismissesItsAddressPalette() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        fixture.manager.restoreWindows()
        let context = try #require(fixture.manager.activeContext)
        let controller = context.controller
        let originalID = controller.model.selectedTabID
        controller.newTab()
        #expect(controller.isAddressPresented)
        #expect(controller.model.tabs.count == 2)
        controller.closeTab()
        #expect(!controller.isAddressPresented)
        #expect(controller.model.tabs.count == 1)
        #expect(controller.model.selectedTabID == originalID)
        // A subsequent new tab must still open a fresh palette normally.
        controller.newTab()
        #expect(controller.isAddressPresented)
        #expect(controller.addressText.isEmpty)
    }

    @Test func closingLastTabWithAddressPaletteStillClosesOnlyItsWindow() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        fixture.manager.restoreWindows()
        let first = try #require(fixture.manager.activeContext)
        let other = try #require(fixture.manager.newWindow())
        first.controller.showAddress()
        first.controller.closeTab()
        #expect(!first.controller.isAddressPresented)
        #expect(fixture.manager.windows.count == 1)
        #expect(fixture.manager.windows.first === other)
    }

    @Test func windowsOwnTheirTabsAndTransientUIWhileSharingAppearanceAndWebsiteStore() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.restoreWindows()
        let first = try #require(manager.activeContext)
        let second = try #require(manager.newWindow())

        #expect(first.controller !== second.controller)
        #expect(first.controller.model !== second.controller.model)
        #expect(first.controller.passwords !== second.controller.passwords)
        #expect(first.controller.appearance === second.controller.appearance)
        #expect(first.controller.appearance === manager.appearance)
        #expect(first.controller.preferences === second.controller.preferences)
        #expect(first.controller.preferences === manager.preferences)
        manager.preferences.selectSearchEngine(.duckDuckGo)
        #expect(second.controller.preferences.searchEngine == .duckDuckGo)
        let firstTab = try #require(first.controller.model.selectedTab)
        let secondTab = try #require(second.controller.model.selectedTab)
        #expect(firstTab.webView !== secondTab.webView)
        #expect(firstTab.webView.configuration.websiteDataStore === secondTab.webView.configuration.websiteDataStore)
        #expect(firstTab.webView.configuration.websiteDataStore.isPersistent)

        first.controller.addressText = "Window One"
        first.controller.toast = "First window only"
        first.controller.passwords.presentImport()
        #expect(second.controller.addressText.isEmpty)
        #expect(second.controller.toast == nil)
        #expect(!second.controller.passwords.isPresented)
        #expect(second.controller.model.tabs.count == 1)
        #expect(secondTab.url == nil)
    }

    @Test func settingsCanImportPasswordsWithoutABrowserWindow() {
        let importer = BrowserPasswordController()
        #expect(importer.model == nil)
        #expect(!importer.canFill)
        importer.presentFill()
        #expect(!importer.isPresented)
        importer.presentImport()
        #expect(importer.isPresented)
        #expect(importer.mode == .importing)
        importer.dismiss()
        #expect(!importer.isPresented)
    }

    @Test func commandsFollowTheLatestKeyBrowserWindow() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.restoreWindows()
        let first = try #require(manager.activeContext)
        let second = try #require(manager.newWindow())
        first.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: first.window))
        manager.newTab()
        #expect(manager.activeController === first.controller)
        #expect(first.controller.model.tabs.count == 2)
        #expect(second.controller.model.tabs.count == 1)

        first.controller.passwords.presentImport()
        #expect(first.controller.passwords.isPresented)
        second.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: second.window))
        #expect(!first.controller.passwords.isPresented)
        manager.newTab()
        #expect(manager.activeController === second.controller)
        #expect(first.controller.model.tabs.count == 2)
        #expect(second.controller.model.tabs.count == 2)
        #expect(second.controller.isAddressPresented)
        let reloaded = BrowserWorkspaceStore(sessionURL: fixture.sessionURL)
        #expect(reloaded.restoredActiveWindowID == second.session.id)
    }

    @Test func closingOneWindowStopsItsPageAndKeepsTheOtherWindowIntact() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.restoreWindows()
        let first = try #require(manager.activeContext)
        let second = try #require(manager.newWindow())
        let survivingPage = try #require(first.controller.model.selectedTab?.webView)
        let closingPage = try #require(second.controller.model.selectedTab?.webView)
        second.controller.passwords.presentImport()
        manager.closeActiveWindow()

        #expect(manager.windows.count == 1)
        #expect(manager.activeController === first.controller)
        #expect(first.controller.model.selectedTab?.webView === survivingPage)
        #expect(survivingPage.navigationDelegate != nil)
        #expect(closingPage.navigationDelegate == nil)
        #expect(closingPage.uiDelegate == nil)
        #expect(second.window.contentView == nil)
        #expect(!second.controller.passwords.isPresented)
        let reloaded = BrowserWorkspaceStore(sessionURL: fixture.sessionURL)
        #expect(reloaded.restoredWindows == [first.session])
    }

    @Test func closingTabsClosesOnlyTheirOwnWindowWhenItsFinalTabIsReached() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.restoreWindows()
        let first = try #require(manager.activeContext)
        let remainingTab = try #require(first.controller.model.selectedTab)
        first.controller.newTab()
        let second = try #require(manager.newWindow())
        let otherTab = try #require(second.controller.model.selectedTab)
        let otherPage = otherTab.webView

        first.controller.closeTab()
        #expect(manager.windows.count == 2)
        #expect(first.controller.model.tabs.count == 1)
        #expect(first.controller.model.selectedTab === remainingTab)
        #expect(remainingTab.webView.navigationDelegate != nil)
        #expect(second.controller.model.selectedTab === otherTab)
        #expect(second.controller.model.selectedTab?.webView === otherPage)

        // The manager's active window is the second one. The callback must
        // still close the first tab's owning window, never the active peer.
        first.controller.closeTab()
        #expect(manager.windows.count == 1)
        #expect(manager.activeContext === second)
        #expect(first.controller.model.tabs.count == 1)
        #expect(first.controller.model.selectedTab === remainingTab)
        #expect(first.controller.model.onLastTabClosed == nil)
        #expect(remainingTab.webView.navigationDelegate == nil)
        #expect(second.controller.model.selectedTab?.webView === otherPage)
        #expect(otherPage.navigationDelegate != nil)
        let store = BrowserWorkspaceStore(sessionURL: fixture.sessionURL)
        #expect(store.restoredWindows == [second.session])
        let saved = try JSONDecoder().decode(BrowserSession.self, from: Data(contentsOf: store.sessionURL(for: first.session)))
        #expect(saved.tabs.map(\.id) == [remainingTab.id])

        // Late webpage close notifications from the old view cannot act on
        // another window or replace its preserved final tab with a new one.
        first.controller.model.closeTab(remainingTab.id)
        #expect(manager.windows.count == 1)
        #expect(first.controller.model.tabs.map(\.id) == [remainingTab.id])
    }

    @Test func closingTheFinalWindowsLastTabPersistsNoWindowsAndNewTabStartsOneBlankTab() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.restoreWindows()
        let closed = try #require(manager.activeContext)
        let lastID = try #require(closed.controller.model.selectedTabID)
        closed.controller.closeTab()

        #expect(manager.windows.isEmpty)
        #expect(manager.activeController == nil)
        #expect(closed.controller.model.tabs.map(\.id) == [lastID])
        #expect(closed.controller.model.onLastTabClosed == nil)
        #expect(BrowserWorkspaceStore(sessionURL: fixture.sessionURL).restoredWindows.isEmpty)

        manager.newTab()
        let fresh = try #require(manager.activeContext)
        #expect(manager.windows.count == 1)
        #expect(fresh !== closed)
        #expect(fresh.controller.model.tabs.count == 1)
        #expect(fresh.controller.model.selectedTabID != lastID)
        #expect(fresh.controller.model.selectedTab?.url == nil)
        #expect(fresh.controller.isAddressPresented)
        #expect(BrowserWorkspaceStore(sessionURL: fixture.sessionURL).restoredWindows == [fresh.session])
    }

    @Test func keyBrowserControllerClearsForSettingsAndReturnsWithoutLosingTheActiveWindow() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.restoreWindows()
        let first = try #require(manager.activeContext)

        first.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: first.window))
        #expect(manager.keyWindowID == first.session.id)
        #expect(manager.keyController === first.controller)

        // A Settings or other non-browser window becoming key resigns the
        // browser's key status without changing its last-active identity.
        first.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: first.window))
        #expect(manager.keyWindowID == nil)
        #expect(manager.keyController == nil)
        #expect(manager.activeController === first.controller)

        first.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: first.window))
        #expect(manager.keyController === first.controller)

        let second = try #require(manager.newWindow())
        second.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: second.window))
        // A late resignation from the former window cannot clear the new key.
        first.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: first.window))
        #expect(manager.keyController === second.controller)

        second.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: second.window))
        #expect(manager.keyController == nil)
        #expect(manager.activeController === second.controller)
        second.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: second.window))
        #expect(manager.keyController === second.controller)

        manager.closeWindow(second.session.id)
        #expect(manager.keyWindowID == nil)
        #expect(manager.keyController == nil)
        #expect(manager.activeController === first.controller)
        #expect(second.onResignKey == nil)
    }

    @Test func newTabWithNoWindowsCreatesExactlyOneBlankTabAndCallbacksTargetTheirWindow() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.restoreWindows()
        manager.closeActiveWindow()
        #expect(manager.windows.isEmpty)
        #expect(BrowserWorkspaceStore(sessionURL: fixture.sessionURL).restoredWindows.isEmpty)
        manager.newTab()
        let first = try #require(manager.activeContext)
        #expect(manager.windows.count == 1)
        #expect(first.controller.model.tabs.count == 1)
        #expect(first.controller.model.selectedTab?.url == nil)
        #expect(first.controller.isAddressPresented)

        first.controller.newWindow()
        #expect(manager.windows.count == 2)
        let second = try #require(manager.activeContext)
        #expect(second !== first)
        first.controller.closeWindow()
        #expect(manager.windows.count == 1)
        #expect(manager.activeContext === second)
    }

    @Test func externalHTMLOnFirstLaunchCreatesOneTargetTabWithoutAnApplePage() throws {
        let fixture = try fixture(restoringBlankWindow: false)
        defer { fixture.cleanUp() }
        let page = fixture.directory.appendingPathComponent("target.html")
        try "<!doctype html><title>Local target</title>".write(to: page, atomically: true, encoding: .utf8)
        let manager = fixture.manager
        manager.open([page])
        #expect(manager.windows.count == 1)
        #expect(manager.activeController?.model.tabs.count == 1)
        #expect(manager.activeController?.model.selectedTab?.url == page)
        // A later launch notification must not restore a second workspace.
        manager.restoreWindows()
        #expect(manager.windows.count == 1)
        manager.closeActiveWindow()
        manager.open([page])
        #expect(manager.windows.count == 1)
        #expect(manager.activeController?.model.tabs.count == 1)
        #expect(manager.activeController?.model.selectedTab?.url == page)
    }

    @Test func terminationPreservesAllOpenWindowSessionsAndTheActiveIdentity() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.restoreWindows()
        let first = try #require(manager.activeContext)
        let second = try #require(manager.newWindow())
        first.controller.newTab()
        second.controller.newTab()
        second.controller.newTab()
        manager.activate(first)
        let expectedSessions = manager.windows.map(\.session)
        let expectedTabs = manager.windows.map { $0.controller.model.tabs.map(\.id) }
        manager.prepareForTermination()
        manager.windows.forEach { $0.window.close() }

        let reloaded = BrowserWorkspaceStore(sessionURL: fixture.sessionURL)
        #expect(reloaded.restoredWindows == expectedSessions)
        #expect(reloaded.restoredActiveWindowID == first.session.id)
        for (index, session) in reloaded.restoredWindows.enumerated() {
            let data = try Data(contentsOf: reloaded.sessionURL(for: session))
            let saved = try JSONDecoder().decode(BrowserSession.self, from: data)
            #expect(saved.tabs.map(\.id) == expectedTabs[index])
        }
    }

    @Test func standardZoomUsesTheWindowsCurrentScreensVisibleFrameWithoutChangingItsFrame() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        fixture.manager.restoreWindows()
        let context = try #require(fixture.manager.activeContext)
        let window = context.window
        let originalFrame = window.frame
        let proposedFrame = NSRect(x: 31, y: 47, width: 611, height: 433)
        let expected = window.screen?.visibleFrame ?? proposedFrame

        let standard = context.windowWillUseStandardFrame(window, defaultFrame: proposedFrame)

        #expect(standard == expected)
        #expect(window.frame == originalFrame)
        #expect(!window.styleMask.contains(.fullScreen))
    }

    @Test func standardZoomFallsBackForASenderWithoutAScreen() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        fixture.manager.restoreWindows()
        let context = try #require(fixture.manager.activeContext)
        let sender = ScreenlessWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        sender.isReleasedWhenClosed = false
        defer { sender.close() }
        let proposedFrame = NSRect(x: -320, y: 80, width: 1_200, height: 800)

        #expect(sender.screen == nil)
        #expect(context.windowWillUseStandardFrame(sender, defaultFrame: proposedFrame) == proposedFrame)
    }

    private final class ScreenlessWindow: NSWindow {
        override var screen: NSScreen? { nil }
    }
}
