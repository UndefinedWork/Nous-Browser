import AppKit
import Foundation
import Testing
@testable import NousBrowser

@Suite("Chromium foreground and background link destinations", .serialized)
@MainActor
struct ChromiumLinkDispositionTests {
    @MainActor private struct Fixture {
        let directory: URL
        let sessionURL: URL
        let target: URL
        let model: BrowserModel
        func cleanUp() {
            model.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func fixture(pinned: Bool = false) throws -> Fixture {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var tabs: [BrowserSession.Tab] = []
        for index in 0..<3 {
            let url = directory.appendingPathComponent("source-\(index).html")
            try "<!doctype html><title>Local disposition fixture</title>".write(to: url, atomically: true, encoding: .utf8)
            tabs.append(.init(id: UUID(), title: "Source \(index)", url: url, isPinned: pinned && index < 2))
        }
        let sessionURL = directory.appendingPathComponent("session.json")
        try JSONEncoder().encode(BrowserSession(tabs: tabs, selectedTabID: tabs.last?.id, isSidebarVisible: true)).write(to: sessionURL)
        let model = BrowserModel(sessionURL: sessionURL, loadSelectedTab: false)
        let target = directory.appendingPathComponent("target.html")
        try "<!doctype html><title>Target</title>".write(to: target, atomically: true, encoding: .utf8)
        return Fixture(directory: directory, sessionURL: sessionURL, target: target, model: model)
    }

    @Test func backgroundLinkKeepsSelectionAndUsesTheSourceViewportWithoutMounting() throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let source = f.model.tabs[0], selected = try #require(f.model.selectedTab)
        source.webView.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
        #if DEBUG
        var selectedChanges = 0
        selected.onNativeLifecycleUpdate = { _, _, _ in selectedChanges += 1 }
        #endif

        let opened = try #require(f.model.openLinkInNewTab(f.target, after: source.id, activate: false))

        #expect(f.model.tabs[1] === opened)
        #expect(f.model.selectedTab === selected)
        #if DEBUG
        #expect(selectedChanges == 0)
        #endif
        #expect(opened.url == f.target && opened.hasWebContent)
        #expect(opened.webView.isHidden)
        #expect(opened.webView.superview == nil)
        #expect(opened.webView.frame.size == NSSize(width: 1100, height: 760))
        let saved = try JSONDecoder().decode(BrowserSession.self, from: Data(contentsOf: f.sessionURL))
        #expect(saved.selectedTabID == selected.id)
        #expect(saved.tabs[1].id == opened.id && saved.tabs[1].url == f.target)
    }

    @Test func foregroundLinkSelectsImmediatelyAndBackgroundLinksDoNotSplitPins() throws {
        let f = try fixture(pinned: true)
        defer { f.cleanUp() }
        let original = f.model.tabs
        let background = try #require(f.model.openLinkInNewTab(f.target, after: original[0].id, activate: false))
        #expect(f.model.tabs.map(\.id) == [original[0].id, original[1].id, background.id, original[2].id])
        #expect(f.model.selectedTab === original[2])
        let foreground = try #require(f.model.openLinkInNewTab(f.target, after: original[0].id, activate: true))
        #expect(f.model.tabs[2] === foreground)
        #expect(f.model.selectedTab === foreground)
        #expect(!foreground.webView.isHidden && !foreground.isPinned)
    }

    @Test func nativePopupHandlerCarriesActivationWithoutRecreatingTheReturnedHost() throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let source = f.model.tabs[0], selected = try #require(f.model.selectedTab)
        let handler = try #require(source.webView.popupHandler)

        let backgroundView = try #require(handler(false, false))
        let background = try #require(f.model.tabs.first { $0.webView === backgroundView })
        #expect(f.model.tabs[1] === background)
        #expect(f.model.selectedTab === selected)
        #expect(backgroundView.isHidden && background.hasWebContent)
        #expect(background.url == nil) // CEF, not a duplicate LoadURL, owns the popup navigation.

        let foregroundView = try #require(handler(false, true))
        #expect(f.model.selectedTab?.webView === foregroundView)
        #expect(foregroundView !== backgroundView && !foregroundView.isHidden)
    }

    @Test func nativeWindowPopupUsesTheWindowFactoryAndLeavesSourceSelectionAlone() throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let source = f.model.tabs[0], selection = f.model.selectedTabID
        let originalIDs = f.model.tabs.map(\.id)
        let destination = BrowserTab(owner: nil, isPopup: true)
        defer { destination.shutdown() }
        var calls = 0
        f.model.onCreateChromiumPopupWindow = { calls += 1; return destination }

        let returned = source.webView.popupHandler?(true, true)

        #expect(returned === destination.webView)
        #expect(calls == 1)
        #expect(f.model.tabs.map(\.id) == originalIDs)
        #expect(f.model.selectedTabID == selection)
    }

    @Test func trustedImageBackgroundOpeningDoesNotBroadenExternalURLPolicy() throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let source = f.model.tabs[0], selection = f.model.selectedTabID
        let image = try #require(URL(string: "data:image/png;base64,iVBORw0KGgo="))
        #expect(f.model.openLinkInNewTab(image, after: source.id, activate: false) == nil)
        f.model.openChromiumImage(image, after: source.id, inNewWindow: false, activate: false)
        #expect(f.model.tabs[1].url == image)
        #expect(f.model.tabs[1].webView.isHidden)
        #expect(f.model.selectedTabID == selection)
        #expect(f.model.openChromiumPopup(after: UUID(), newWindow: false, activate: false) == nil)
    }
}
