import AppKit
import Foundation
import Testing
import WebKit
@testable import NousBrowser

@Suite("Reload, page zoom and numbered tab shortcuts", .serialized)
@MainActor
struct BrowserReloadZoomShortcutTests {
    @MainActor private struct Fixture {
        let directory: URL
        let model: BrowserModel

        func cleanUp() {
            model.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func fixture(tabCount: Int = 1, blank: Bool = false) throws -> Fixture {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.json")
        // Restoring unopened about:blank pages gives each tab its own real
        // WKWebView without network requests, user history or a password store.
        let tabs = (0..<tabCount).map { index in
            BrowserSession.Tab(id: UUID(), title: "Synthetic tab \(index + 1)",
                               url: blank ? nil : URL(string: "about:blank"))
        }
        let session = BrowserSession(tabs: tabs, selectedTabID: tabs.first?.id, isSidebarVisible: true)
        try JSONEncoder().encode(session).write(to: file)
        return Fixture(directory: directory,
                       model: BrowserModel(sessionURL: file, loadSelectedTab: false, startWithBlankTab: true))
    }

    @Test func ordinaryAndBypassingReloadLeaveAnEmptyTabUnchanged() throws {
        let fixture = try fixture(blank: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let tab = try #require(model.selectedTab)
        let webView = tab.webView
        for bypassingCache in [false, true] {
            model.reload(bypassingCache: bypassingCache)
            #expect(model.tabs.count == 1)
            #expect(model.selectedTab === tab)
            #expect(tab.webView === webView)
            #expect(tab.url == nil && tab.webView.url == nil)
            #expect(!tab.hasWebContent && !tab.webView.isLoading)
        }
    }

    @Test func zoomTraversesTheSpecifiedStopsAndClampsAtBothEnds() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let webView = try #require(model.selectedTab?.webView)
        webView.pageZoom = 1
        for expected in [1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5] as [CGFloat] {
            model.zoomIn()
            #expect(abs(webView.pageZoom - expected) < 0.000_001)
        }
        model.zoomIn()
        model.zoomIn()
        #expect(webView.pageZoom == 5)

        for expected in [4.0, 3, 2.5, 2, 1.75, 1.5, 1.25, 1.1, 1, 0.9, 0.8, 0.75, 0.67, 0.5, 0.33, 0.25] as [CGFloat] {
            model.zoomOut()
            #expect(abs(webView.pageZoom - expected) < 0.000_001)
        }
        model.zoomOut()
        model.zoomOut()
        #expect(webView.pageZoom == 0.25)
        model.resetZoom()
        #expect(webView.pageZoom == 1)
    }

    @Test func zoomChangesOnlyTheSelectedPageAndPreservesOtherPagesFactors() throws {
        let fixture = try fixture(tabCount: 2)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let first = model.tabs[0]
        let second = model.tabs[1]
        first.webView.pageZoom = 1.25
        second.webView.pageZoom = 0.8

        model.zoomIn()
        #expect(first.webView.pageZoom == 1.5)
        #expect(second.webView.pageZoom == 0.8)
        model.zoomOut()
        #expect(first.webView.pageZoom == 1.25)
        #expect(second.webView.pageZoom == 0.8)

        model.selectTab(second.id)
        model.zoomIn()
        #expect(second.webView.pageZoom == 0.9)
        #expect(first.webView.pageZoom == 1.25)
        model.resetZoom()
        #expect(second.webView.pageZoom == 1)
        #expect(first.webView.pageZoom == 1.25)
        #expect(model.selectedTabID == second.id)
    }

    @Test func zoomChoosesAdjacentStopsWhenTheCurrentFactorIsBetweenStops() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let webView = try #require(model.selectedTab?.webView)
        webView.pageZoom = 1.12
        model.zoomIn()
        #expect(webView.pageZoom == 1.25)
        webView.pageZoom = 1.12
        model.zoomOut()
        #expect(webView.pageZoom == 1.1)
        webView.pageZoom = 0.3
        model.zoomIn()
        #expect(webView.pageZoom == 0.33)
        webView.pageZoom = 0.3
        model.zoomOut()
        #expect(webView.pageZoom == 0.25)
    }

    @Test func numberedSelectionUsesTheCurrentVisibleOrderAndNineMeansTheLastTab() throws {
        let fixture = try fixture(tabCount: 10)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let originallyFourth = model.tabs[3]
        model.togglePin(originallyFourth.id)
        #expect(model.tabs.first === originallyFourth)
        let originallyLast = model.tabs.last!
        model.moveTab(originallyLast.id, to: 1)
        #expect(model.tabs[1] === originallyLast)
        let visibleOrder = model.tabs.map(\.id)

        for number in 1...8 {
            model.selectTab(number: number)
            #expect(model.selectedTabID == visibleOrder[number - 1])
            #expect(model.tabs.map(\.id) == visibleOrder)
        }
        model.selectTab(number: 9)
        #expect(model.selectedTabID == visibleOrder.last)
        #expect(model.selectedTabID != visibleOrder[8])
    }

    @Test func missingAndOutOfRangeTabNumbersDoNothing() throws {
        let fixture = try fixture(tabCount: 3)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let initial = model.selectedTabID
        let order = model.tabs.map(\.id)
        for number in [-1, 0, 4, 8, 10, 99] {
            model.selectTab(number: number)
            #expect(model.selectedTabID == initial)
            #expect(model.tabs.map(\.id) == order)
            #expect(model.tabs.allSatisfy { $0.webView.url == nil })
        }
        model.selectTab(number: 9)
        #expect(model.selectedTabID == order.last)
    }

    @Test func emptyTabsDoNotReceivePageZoomActions() throws {
        let fixture = try fixture(blank: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let webView = try #require(model.selectedTab?.webView)
        webView.pageZoom = 1.25
        model.zoomIn()
        #expect(webView.pageZoom == 1.25)
        model.zoomOut()
        #expect(webView.pageZoom == 1.25)
        model.resetZoom()
        #expect(webView.pageZoom == 1.25)
    }

    private func event(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags,
                       type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: characters, charactersIgnoringModifiers: characters,
                                     isARepeat: false, keyCode: keyCode))
    }

    @Test func tabAndZoomAliasesAcceptTheirExactSemanticModifierCombinations() throws {
        let modifiers: [NSEvent.ModifierFlags] = [.command, .shift, .control, .option]
        for bits in 0..<16 {
            var flags: NSEvent.ModifierFlags = []
            for (index, modifier) in modifiers.enumerated() where bits & (1 << index) != 0 {
                flags.insert(modifier)
            }
            let tab = try event(keyCode: 48, characters: "\t", modifiers: flags)
            let tabAction: BrowserShortcutAliases.Action? = flags == .control ? .nextTab
                : flags == [.control, .shift] ? .previousTab : nil
            #expect(BrowserShortcutAliases.action(for: tab) == tabAction)

            let left = try event(keyCode: 123, characters: "\u{F702}", modifiers: flags)
            let right = try event(keyCode: 124, characters: "\u{F703}", modifiers: flags)
            let arrowModifiers = flags == [.command, .option]
            #expect(BrowserShortcutAliases.action(for: left) == (arrowModifiers ? .previousTab : nil))
            #expect(BrowserShortcutAliases.action(for: right) == (arrowModifiers ? .nextTab : nil))

            let plus = try event(keyCode: 24, characters: "+", modifiers: flags)
            let zoomModifiers = flags == .command || flags == [.command, .shift]
            #expect(BrowserShortcutAliases.action(for: plus) == (zoomModifiers ? .zoomIn : nil))
        }
    }

    @Test func aliasesIgnoreKeyUpAndUnrelatedCharacters() throws {
        for (keyCode, characters, flags) in [
            (UInt16(48), "\t", NSEvent.ModifierFlags.control),
            (UInt16(48), "\t", [.control, .shift]),
            (UInt16(123), "\u{F702}", [.command, .option]),
            (UInt16(124), "\u{F703}", [.command, .option]),
            (UInt16(24), "+", .command),
            (UInt16(24), "+", [.command, .shift])
        ] {
            #expect(BrowserShortcutAliases.action(for: try event(keyCode: keyCode, characters: characters,
                                                                 modifiers: flags, type: .keyUp)) == nil)
        }
        for character in ["=", "-", "0", "x"] {
            #expect(BrowserShortcutAliases.action(for: try event(keyCode: 24, characters: character,
                                                                 modifiers: .command)) == nil)
        }
    }
}
