import AppKit
import Foundation
import Testing
import WebKit
@testable import NousBrowser

@Suite("Web view deck")
struct WebViewDeckTests {
    @MainActor private func makeModel(tabCount: Int) throws -> (model: BrowserModel, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var tabs: [BrowserSession.Tab] = []
        for index in 0..<tabCount {
            let page = directory.appendingPathComponent("deck-\(index).html")
            try "<!doctype html><title>Deck \(index)</title><p>Local deck fixture</p>"
                .write(to: page, atomically: true, encoding: .utf8)
            tabs.append(.init(id: UUID(), title: "Deck \(index)", url: page))
        }
        let file = directory.appendingPathComponent("session.json")
        let session = BrowserSession(tabs: tabs, selectedTabID: tabs.last?.id, isSidebarVisible: true)
        try JSONEncoder().encode(session).write(to: file)
        // File URLs are eligible deck pages without starting a navigation or
        // involving the shared favicon cache. Tests only attach these views.
        let model = BrowserModel(sessionURL: file, loadSelectedTab: false)
        return (model, directory)
    }

    @MainActor private func hostedDeck() -> (deck: WebViewDeckView, window: NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let deck = WebViewDeckView(frame: window.contentLayoutRect)
        window.contentView = deck
        return (deck, window)
    }

    @Test @MainActor func switchingOnlyTogglesVisibilityOfAttachedPages() throws {
        let setup = try makeModel(tabCount: 3)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let (deck, _) = hostedDeck()
        let tabs = setup.model.tabs
        for tab in tabs { deck.show(tabs, selectedID: tab.id) }
        #expect(tabs.allSatisfy { $0.webView.superview === deck })

        deck.show(tabs, selectedID: tabs[0].id)
        #expect(!tabs[0].webView.isHidden)
        #expect(tabs[1].webView.isHidden && tabs[2].webView.isHidden)
        #expect(tabs[0].webView.frame == deck.bounds)

        deck.show(tabs, selectedID: tabs[2].id)
        #expect(tabs.allSatisfy { $0.webView.superview === deck })
        #expect(tabs[0].webView.isHidden && !tabs[2].webView.isHidden)
    }

    @Test @MainActor func blankSelectionHidesEveryPageAndClosedTabsAreReleased() throws {
        let setup = try makeModel(tabCount: 3)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let (deck, _) = hostedDeck()
        let model = setup.model
        for tab in model.tabs { deck.show(model.tabs, selectedID: tab.id) }
        deck.show(model.tabs, selectedID: nil)
        #expect(model.tabs.allSatisfy { $0.webView.superview !== deck || $0.webView.isHidden })

        let closed = model.tabs[1]
        model.closeTab(closed.id)
        deck.show(model.tabs, selectedID: model.selectedTabID)
        #expect(closed.webView.superview == nil)
        #expect(deck.subviews.count == 2)
    }

    @Test @MainActor func focusLeavesAHiddenPageForTheVisibleOne() throws {
        let setup = try makeModel(tabCount: 2)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let (deck, window) = hostedDeck()
        let tabs = setup.model.tabs
        deck.show(tabs, selectedID: tabs[0].id)
        deck.show(tabs, selectedID: tabs[1].id)
        #expect(window.makeFirstResponder(tabs[1].webView))
        deck.show(tabs, selectedID: tabs[0].id)
        let responder = window.firstResponder as? NSView
        #expect(responder.map { !$0.isDescendant(of: tabs[1].webView) } ?? true)
        #expect(responder?.isDescendant(of: tabs[0].webView) == true)
    }

    @Test @MainActor func aPageInFullscreenIsNotPulledBackIntoTheDeck() throws {
        let setup = try makeModel(tabCount: 2)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let (deck, _) = hostedDeck()
        let tabs = setup.model.tabs
        deck.show(tabs, selectedID: tabs[0].id)
        let fullscreenHost = NSView()
        fullscreenHost.addSubview(tabs[0].webView)
        deck.show(tabs, selectedID: tabs[0].id)
        deck.show(tabs, selectedID: tabs[1].id)
        #expect(tabs[0].webView.superview === fullscreenHost)
        #expect(!tabs[0].webView.isHidden)
    }

    @Test @MainActor func onlyRecentlyShownPagesStayAttached() throws {
        let limit = WebViewDeckView.attachedLimit
        let setup = try makeModel(tabCount: limit + 3)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let (deck, _) = hostedDeck()
        let tabs = setup.model.tabs
        for tab in tabs { deck.show(tabs, selectedID: tab.id) }
        #expect(deck.subviews.count == limit)
        #expect(tabs.prefix(3).allSatisfy { $0.webView.superview == nil })
        deck.show(tabs, selectedID: tabs[0].id)
        #expect(tabs[0].webView.superview === deck && !tabs[0].webView.isHidden)
        #expect(deck.subviews.count == limit)
    }

    @Test func attachedSetPrefersRecentEligiblePages() {
        let ids = (0..<5).map { _ in UUID() }
        let eligible = Set([ids[0], ids[2], ids[3], ids[4]])
        #expect(WebViewDeckView.attachedIDs(recent: ids, eligible: eligible, limit: 2) == [ids[0], ids[2]])
        #expect(WebViewDeckView.attachedIDs(recent: [], eligible: eligible, limit: 2).isEmpty)
    }
}
