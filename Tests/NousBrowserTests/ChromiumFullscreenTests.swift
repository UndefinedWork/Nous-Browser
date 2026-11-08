import AppKit
import Foundation
import Testing
@testable import NousBrowser

@Suite("Chromium fullscreen chrome projection", .serialized)
@MainActor
struct ChromiumFullscreenTests {
    @Test func fullscreenTemporarilyHidesChromeWithoutChangingSidebarPreference() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = BrowserModel(sessionURL: directory.appendingPathComponent("session.json"),
            restoreSession: false, loadSelectedTab: false, startWithBlankTab: true)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let tab = try #require(model.selectedTab)
        for (visible, compact) in [(true, false), (true, true), (false, true)] {
            model.isSidebarVisible = visible
            model.isSidebarCompact = compact
            tab.webView.eventHandler?("state", ["fullscreen": true])
            await flushEvents()
            #expect(model.isPageFullscreen)
            #expect(!model.isSidebarPresented)
            #expect(model.isSidebarVisible == visible)
            #expect(model.isSidebarCompact == compact)

            tab.webView.eventHandler?("state", ["fullscreen": false])
            await flushEvents()
            #expect(!model.isPageFullscreen)
            #expect(model.isSidebarPresented == visible)
            #expect(model.isSidebarCompact == compact)
        }
    }

    @Test func backgroundFullscreenNotificationsCannotHideAnotherTabsChrome() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = BrowserModel(sessionURL: directory.appendingPathComponent("session.json"),
            restoreSession: false, loadSelectedTab: false, startWithBlankTab: true)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let first = try #require(model.selectedTab)
        first.webView.eventHandler?("state", ["fullscreen": true])
        await flushEvents()
        #expect(!model.isSidebarPresented)
        model.newTab()
        #expect(model.isSidebarPresented)
        first.webView.eventHandler?("state", ["fullscreen": false])
        await flushEvents()
        #expect(model.isSidebarPresented)
    }

    private func flushEvents() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
