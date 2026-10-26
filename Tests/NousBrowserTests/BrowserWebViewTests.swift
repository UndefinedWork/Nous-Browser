import AppKit
import JavaScriptCore
import Testing
import WebKit
@testable import NousBrowser

@Suite("Native webpage link and search context menus", .serialized)
@MainActor
struct BrowserWebViewTests {
    @Test func validatesTheClickedFrameRatherThanTheTopLevelOrigin() throws {
        let body: [String: Any] = ["href": "https://destination.example/path?q=one#two",
                                   "documentURL": "https://frame.example:8443/sub/page"]
        #expect(BrowserWebView.linkURL(from: body, frameScheme: "https", frameHost: "frame.example", framePort: 8443)?.absoluteString == "https://destination.example/path?q=one#two")
        #expect(BrowserWebView.linkURL(from: body, frameScheme: "https", frameHost: "top.example", framePort: 8443) == nil)
        #expect(BrowserWebView.linkURL(from: body, frameScheme: "https", frameHost: "frame.example", framePort: 443) == nil)
        #expect(BrowserWebView.linkURL(from: body, frameScheme: "http", frameHost: "frame.example", framePort: 8443) == nil)
        let defaultPort: [String: Any] = ["href": "http://destination.example/", "documentURL": "https://frame.example/page"]
        #expect(BrowserWebView.linkURL(from: defaultPort, frameScheme: "HTTPS", frameHost: "FRAME.EXAMPLE", framePort: 443) != nil)
    }

    @Test func unsupportedLinksAndMalformedMessagesRemainWebKitsResponsibility() {
        for href in ["javascript:alert(1)", "data:text/html,test", "file:///tmp/fixture.html", "mailto:fixture@example.test",
                     "/unresolved-relative", "https:///", "https://user:password@example.test/"] {
            let body: [String: Any] = ["href": href, "documentURL": "https://frame.example/"]
            #expect(BrowserWebView.linkURL(from: body, frameScheme: "https", frameHost: "frame.example", framePort: 0) == nil)
        }
        let malformed: [Any] = [NSNull(), "https://example.test/", ["href": NSNull()],
                                ["href": "https://example.test/"],
                                ["href": "https://example.test/", "documentURL": "not a URL"]]
        for body in malformed {
            #expect(BrowserWebView.linkURL(from: body, frameScheme: "https", frameHost: "frame.example", framePort: 0) == nil)
        }
        for document in ["about:blank", "about:srcdoc"] {
            #expect(BrowserWebView.linkURL(from: ["href": "https://example.test/", "documentURL": document],
                                           frameScheme: "https", frameHost: "frame.example", framePort: 443) != nil)
        }
    }

    @Test func contextMatchesOnlyTheSamePagePositionAndRecentEvent() throws {
        let page = try #require(URL(string: "https://page.example/"))
        let now = Date()
        let context = BrowserWebView.ContextLink(url: page, pageURL: page, eventDate: now,
                                                 screenPoint: NSPoint(x: 240, y: 360))
        #expect(context.matches(pageURL: page, screenPoint: NSPoint(x: 241, y: 359), now: now))
        #expect(!context.matches(pageURL: URL(string: "https://other.example/"), screenPoint: NSPoint(x: 240, y: 360), now: now))
        #expect(!context.matches(pageURL: page, screenPoint: NSPoint(x: 260, y: 360), now: now))
        #expect(!context.matches(pageURL: page, screenPoint: NSPoint(x: 240, y: 360), now: now.addingTimeInterval(2)))
        #expect(!context.matches(pageURL: page, screenPoint: NSPoint(x: 240, y: 360), now: now.addingTimeInterval(-2)))
    }

    @Test func replacingOnlyLinkOpeningItemsPreservesNativeMenuStructureAndImages() throws {
        let view = makeView()
        defer { view.invalidateContextMenu() }
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Open Link", action: nil, keyEquivalent: "")
        let image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        open.image = image
        let window = menu.addItem(withTitle: "Open Link in New Window", action: nil, keyEquivalent: "")
        let download = menu.addItem(withTitle: "Download Linked File", action: nil, keyEquivalent: "")
        let copy = menu.addItem(withTitle: "Copy Link", action: nil, keyEquivalent: "")
        let share = menu.addItem(withTitle: "Share", action: nil, keyEquivalent: "")
        let shareMenu = NSMenu()
        share.submenu = shareMenu
        var tabURLs: [URL] = [], windowURLs: [URL] = []
        view.onOpenLinkInNewTab = { tabURLs.append($0) }
        view.onOpenLinkInNewWindow = { windowURLs.append($0) }
        let link = try #require(URL(string: "https://destination.example/path"))

        view.rewriteLinkItems(in: menu, link: link)

        #expect(menu.items == [open, window, download, copy, share])
        #expect(open.title == L10n.string("Open in New Tab"))
        #expect(open.image === image)
        #expect(window.title == "Open Link in New Window")
        #expect(download.action == nil && download.target == nil)
        #expect(copy.action == nil && copy.target == nil)
        #expect(share.submenu === shareMenu)
        try invoke(open)
        try invoke(window)
        #expect(tabURLs == [link])
        #expect(windowURLs == [link])
        // Dispatch holds the clicked URL, even if a later menu refers elsewhere.
        let anotherMenu = NSMenu()
        anotherMenu.addItem(withTitle: "Open Link", action: nil, keyEquivalent: "")
        view.rewriteLinkItems(in: anotherMenu, link: try #require(URL(string: "https://another.example/")))
        try invoke(open)
        #expect(tabURLs == [link, link])
        view.invalidateContextMenu()
        try invoke(window)
        #expect(windowURLs == [link])
    }

    @Test func localisedNativeTitlesAreRecognisedWhileUnknownItemsAreUntouched() throws {
        let view = makeView()
        defer { view.invalidateContextMenu() }
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "打开链接", action: nil, keyEquivalent: "")
        let window = menu.addItem(withTitle: "在新窗口中打开链接", action: nil, keyEquivalent: "")
        let unknown = menu.addItem(withTitle: "Unknown native action", action: nil, keyEquivalent: "")
        view.rewriteLinkItems(in: menu, link: try #require(URL(string: "https://example.test/")),
                              nativeOpenTitle: "打开链接", nativeWindowTitle: "在新窗口中打开链接")
        #expect(open.title == L10n.string("Open in New Tab"))
        #expect(open.action != nil && window.action != nil)
        #expect(unknown.title == "Unknown native action" && unknown.action == nil && unknown.target == nil)
    }

    @Test func aLaterContextMessageUpdatesBothOwnedActionsToTheSameLatestURL() throws {
        let view = makeView()
        defer { view.invalidateContextMenu() }
        let menu = NSMenu()
        let tab = menu.addItem(withTitle: "Open Link", action: nil, keyEquivalent: "")
        let window = menu.addItem(withTitle: "Open Link in New Window", action: nil, keyEquivalent: "")
        let unrelated = menu.addItem(withTitle: L10n.string("Open in New Tab"), action: nil, keyEquivalent: "")
        let first = try #require(URL(string: "https://first.example/"))
        let latest = try #require(URL(string: "https://latest.example/"))
        var tabs: [URL] = [], windows: [URL] = []
        view.onOpenLinkInNewTab = { tabs.append($0) }
        view.onOpenLinkInNewWindow = { windows.append($0) }

        view.rewriteLinkItems(in: menu, link: first)
        view.rewriteLinkItems(in: menu, link: latest)
        try invoke(tab)
        try invoke(window)

        #expect(tabs == [latest])
        #expect(windows == [latest])
        #expect(unrelated.action == nil && unrelated.target == nil && unrelated.representedObject == nil)
    }

    @Test func selectionMessagesValidateTheActualFrameAndPreserveSearchMeaning() {
        let body: [String: Any] = ["selection": " \nC++ 中文 & test\t", "documentURL": "https://frame.example:8443/page"]
        #expect(BrowserWebView.selectionText(from: body, frameScheme: "https", frameHost: "frame.example", framePort: 8443) == "C++ 中文 & test")
        #expect(BrowserWebView.selectionText(from: body, frameScheme: "https", frameHost: "top.example", framePort: 8443) == nil)
        #expect(BrowserWebView.selectionText(from: body, frameScheme: "https", frameHost: "frame.example", framePort: 443) == nil)
        #expect(BrowserWebView.selectionText(from: body, frameScheme: "http", frameHost: "frame.example", framePort: 8443) == nil)
        let invalidBodies: [Any] = [NSNull(), ["selection": NSNull(), "documentURL": "https://frame.example/"],
                             ["selection": " ", "documentURL": "https://frame.example/"],
                             ["selection": String(repeating: "中", count: 6_000), "documentURL": "https://frame.example/"],
                             ["selection": "text", "documentURL": "not a URL"], ["selection": "text"]]
        for invalid in invalidBodies {
            #expect(BrowserWebView.selectionText(from: invalid, frameScheme: "https", frameHost: "frame.example", framePort: 443) == nil)
        }
        for document in ["about:blank", "about:srcdoc"] {
            #expect(BrowserWebView.selectionText(from: ["selection": "Frame text", "documentURL": document],
                                               frameScheme: "https", frameHost: "frame.example", framePort: 443) == "Frame text")
        }
    }

    @Test func selectionContextRejectsStaleDifferentPageAndDifferentLocationMessages() throws {
        let page = try #require(URL(string: "https://page.example/"))
        let now = Date()
        let context = BrowserWebView.ContextSelection(text: "Selected words", pageURL: page, eventDate: now,
                                                      screenPoint: NSPoint(x: 80, y: 120))
        #expect(context.matches(pageURL: page, screenPoint: NSPoint(x: 81, y: 119), now: now))
        #expect(!context.matches(pageURL: URL(string: "https://other.example/"), screenPoint: NSPoint(x: 80, y: 120), now: now))
        #expect(!context.matches(pageURL: page, screenPoint: NSPoint(x: 100, y: 120), now: now))
        #expect(!context.matches(pageURL: page, screenPoint: NSPoint(x: 80, y: 120), now: now.addingTimeInterval(2)))
        #expect(!context.matches(pageURL: page, screenPoint: NSPoint(x: 80, y: 120), now: now.addingTimeInterval(-2)))
    }

    @Test func searchReplacesTheSystemActionAndPreservesNativeEditingItems() throws {
        let view = makeView()
        defer { view.invalidateContextMenu() }
        let menu = NSMenu()
        let search = menu.addItem(withTitle: "Search with Google", action: #selector(NativeActionSpy.invoke(_:)), keyEquivalent: "")
        let originalTarget = NativeActionSpy()
        search.target = originalTarget
        let image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        search.image = image
        let copy = menu.addItem(withTitle: "Copy", action: #selector(NativeActionSpy.invoke(_:)), keyEquivalent: "")
        copy.target = originalTarget
        let lookup = menu.addItem(withTitle: "Look Up “Words”", action: nil, keyEquivalent: "")
        let translate = menu.addItem(withTitle: "Translate “Words”", action: nil, keyEquivalent: "")
        var queries: [String] = []
        view.searchEngineTitle = { BrowserSearchEngine.bing.title }
        view.onSearchSelection = { queries.append($0) }

        view.rewriteSearchItems(in: menu, selection: "C++ 中文 & test")
        #expect(menu.items == [search, copy, lookup, translate])
        #expect(search.title == L10n.format("Search with %@", BrowserSearchEngine.bing.title))
        #expect(search.image === image)
        #expect(search.isEnabled)
        #expect((search.target as? NSObject) !== originalTarget)
        #expect(copy.target as? NativeActionSpy === originalTarget)
        try invoke(search)
        #expect(queries == ["C++ 中文 & test"])
        #expect(originalTarget.calls == 0)
        // Rewriting a later menu must not change the already-dispatched menu's
        // captured selection, which AppKit can invoke after didCloseMenu.
        let later = NSMenu()
        later.addItem(withTitle: "Search with Google", action: nil, keyEquivalent: "")
        view.rewriteSearchItems(in: later, selection: "Later selection")
        try invoke(search)
        #expect(queries == ["C++ 中文 & test", "C++ 中文 & test"])
        view.invalidateContextMenu()
        try invoke(search)
        #expect(queries.count == 2)
    }

    @Test func unavailableSelectionCannotFallBackToTheSystemSearchEvenWhenMenuAutoenablesItems() throws {
        let view = makeView()
        defer { view.invalidateContextMenu() }
        let menu = NSMenu()
        menu.autoenablesItems = true
        let originalTarget = NativeActionSpy()
        let search = menu.addItem(withTitle: "Search with Google", action: #selector(NativeActionSpy.invoke(_:)), keyEquivalent: "")
        search.target = originalTarget
        var queries: [String] = []
        view.onSearchSelection = { queries.append($0) }
        view.rewriteSearchItems(in: menu, selection: nil)
        #expect(!search.isEnabled)
        let validator = try #require(search.target as? NSMenuItemValidation)
        #expect(!validator.validateMenuItem(search))
        try invoke(search)
        #expect(queries.isEmpty && originalTarget.calls == 0)
        view.rewriteSearchItems(in: menu, selection: "Trusted selection")
        #expect(search.isEnabled)
        try invoke(search)
        #expect(queries == ["Trusted selection"])
        #expect(originalTarget.calls == 0)
    }

    @Test func localizedSearchAndServicesEntriesRouteThroughNousWithoutChangingOtherServices() throws {
        let view = makeView()
        defer { view.invalidateContextMenu() }
        let menu = NSMenu()
        let search = menu.addItem(withTitle: "Googleで検索", action: nil, keyEquivalent: "")
        let legacy = menu.addItem(withTitle: "Webを検索", action: nil, keyEquivalent: "")
        let services = menu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        services.submenu = submenu
        let nestedSearch = submenu.addItem(withTitle: "Search With Google", action: nil, keyEquivalent: "")
        let otherService = submenu.addItem(withTitle: "Make New Sticky Note", action: nil, keyEquivalent: "")
        var queries: [String] = []
        view.onSearchSelection = { queries.append($0) }
        view.rewriteSearchItems(in: menu, selection: "選択した文字", nativeSearchFormat: "%[tt]@で検索", nativeWebSearchTitle: "Webを検索")
        #expect(services.submenu === submenu)
        #expect(otherService.target == nil && otherService.action == nil)
        try invoke(search)
        try invoke(legacy)
        try invoke(nestedSearch)
        #expect(queries == Array(repeating: "選択した文字", count: 3))
        #expect(BrowserWebView.matchesSearchTitle("用Google搜索", format: "用%@搜索"))
        #expect(!BrowserWebView.matchesSearchTitle("Googleで検索の設定", format: "%[tt]@で検索"))
        #expect(!BrowserWebView.matchesSearchTitle("で検索", format: "%[tt]@で検索"))
        #expect(!BrowserWebView.matchesSearchTitle("Search options", format: "No placeholder"))
    }

    @Test func externalBrowserServicesAreRemovedWhileEditingAndFileServicesRemain() {
        let services = NSMenu(title: "Services")
        for title in ["Search With Google", "Open URL", "Add to Reading List", "Open", "Open man Page in Terminal", "Ask Claude"] {
            services.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
        BrowserWebView.removeExternalBrowserItems(in: services)
        #expect(services.items.map(\.title) == ["Open", "Open man Page in Terminal", "Ask Claude"])
        let webpage = NSMenu()
        webpage.addItem(withTitle: "Search with Google", action: nil, keyEquivalent: "")
        webpage.addItem(withTitle: "Open with Safari", action: nil, keyEquivalent: "")
        webpage.addItem(withTitle: "Open with Preview", action: nil, keyEquivalent: "")
        BrowserWebView.removeExternalBrowserItems(in: webpage)
        #expect(webpage.items.map(\.title) == ["Search with Google", "Open with Preview"])
    }

    @Test func inheritedPopupConfigurationKeepsItsStoreAndOneAllFrameListener() throws {
        let configuration = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        configuration.websiteDataStore = store
        configuration.userContentController.addUserScript(WKUserScript(source: "window.localFixture = true;",
                                                                         injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.preferences.minimumFontSize = 17
        BrowserWebView.configure(configuration)
        BrowserWebView.configure(configuration)
        let inherited = try #require(configuration.copy() as? WKWebViewConfiguration)
        let first = BrowserWebView(frame: .zero, configuration: configuration)
        let second = BrowserWebView(frame: .zero, configuration: inherited)
        defer { first.invalidateContextMenu(); second.invalidateContextMenu() }
        #expect(first.configuration.websiteDataStore === store)
        #expect(second.configuration.websiteDataStore === store)
        #expect(first.configuration.userContentController === second.configuration.userContentController)
        #expect(configuration.userContentController.userScripts.count == 2)
        #expect(configuration.preferences.minimumFontSize == 17)
        let listener = try #require(configuration.userContentController.userScripts.first { $0.source.contains("nous-browser-link-context-menu-v1") })
        #expect(listener.injectionTime == .atDocumentStart)
        #expect(!listener.isForMainFrameOnly)
        // The final invalidation removes only our handler. The inherited
        // configuration may be reused by another popup without duplicate add.
        first.invalidateContextMenu()
        second.invalidateContextMenu()
        let replacement = BrowserWebView(frame: .zero, configuration: inherited)
        replacement.invalidateContextMenu()
    }

    @Test func pageListenerResolvesFrameBaseAndIgnoresSyntheticAndOrdinaryLeftClicks() throws {
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        var sent = [], listeners = {};
        class Element {
            constructor(href, baseURI) { this.href = href; this.baseURI = baseURI; }
            matches(selector) { return this.href !== null; }
            getAttribute(name) { return name === 'href' ? this.href : null; }
        }
        class URL {
            constructor(href, baseURI) {
                this.href = href.startsWith('https://') ? href : baseURI + href;
            }
        }
        var document = { URL: 'https://iframe.example/page', addEventListener(name, fn) { listeners[name] = fn; } };
        var window = { getSelection() { return { toString() { return 'C++ 中文 & test'; } }; },
            webkit: { messageHandlers: { nousLinkContextMenu: { postMessage(body) { sent.push(body); } } } } };
        """#)
        context.evaluateScript(BrowserWebView.contextMenuSource)
        try #require(context.exception == nil)
        let result = context.evaluateScript(#"""
        const anchor = new Element('relative-target', 'https://iframe.example/base/');
        const event = { isTrusted: true, button: 2, ctrlKey: false, screenX: 10, screenY: 20,
            composedPath() { return [anchor]; },
            preventDefault() { throw new Error('Canceled native menu'); },
            stopPropagation() { throw new Error('Stopped page event'); } };
        listeners.mousedown({...event, button: 0});
        listeners.contextmenu({...event, isTrusted: false});
        listeners.contextmenu(event);
        listeners.mousedown({...event, button: 0, ctrlKey: true});
        listeners.contextmenu({...event, composedPath() { return []; }});
        sent;
        """#)
        try #require(context.exception == nil)
        let messages = try #require(result?.toArray() as? [[String: Any]])
        #expect(messages.count == 3)
        #expect(messages[0]["href"] as? String == "https://iframe.example/base/relative-target")
        #expect(messages[0]["documentURL"] as? String == "https://iframe.example/page")
        #expect(messages[1]["href"] as? String == "https://iframe.example/base/relative-target")
        #expect(messages[2]["href"] is NSNull)
        #expect(messages.allSatisfy { $0["selection"] as? String == "C++ 中文 & test" })
    }

    private func makeView() -> BrowserWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return BrowserWebView(frame: .zero, configuration: configuration)
    }

    private func invoke(_ item: NSMenuItem) throws {
        let target = try #require(item.target as? NSObject)
        let action = try #require(item.action)
        target.perform(action, with: item)
    }
}

@MainActor
private final class NativeActionSpy: NSObject {
    var calls = 0
    @objc func invoke(_ item: NSMenuItem) { calls += 1 }
}
