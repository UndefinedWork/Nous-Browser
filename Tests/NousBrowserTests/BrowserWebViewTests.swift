import AppKit
import JavaScriptCore
import Testing
import WebKit
@testable import NousBrowser

@Suite("Native webpage link and search context menus", .serialized)
@MainActor
struct BrowserWebViewTests {
    @Test func imageCopyForwardsOriginalSenderAndRecoversOnlyWhenNativeCopyDoesNothing() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let spy = ImageCopySpy()
        let item = NSMenuItem(title: "Copy Image", action: #selector(ImageCopySpy.copy(_:)), keyEquivalent: "")
        item.target = spy
        let nativeContext = NSObject()
        item.representedObject = nativeContext
        let url = try #require(URL(string: "https://image.example/icon.svg"))
        var recovered: [URL] = []
        let action = BrowserWebView.ImageCopyAction(item: item, imageURL: url, pasteboard: board,
            isValid: { true }, recover: { source, count, _ in
                #expect(count == board.changeCount)
                recovered.append(source)
            })
        item.representedObject = action
        item.target = action
        action.copyImage(item)
        #expect(spy.calls == 1)
        #expect(spy.representedObject === nativeContext)
        try await Task.sleep(for: .milliseconds(350))
        #expect(recovered == [url])

        // A successful native copy keeps its formats and needs no fallback.
        recovered = []
        spy.write = { board.clearContents(); board.setString("native", forType: .string) }
        action.copyImage(item)
        try await Task.sleep(for: .milliseconds(350))
        #expect(recovered.isEmpty)
        #expect(board.string(forType: .string) == "native")

        // Nor may a delayed fallback replace the user's next copy.
        spy.write = nil
        action.copyImage(item)
        board.clearContents()
        board.setString("next copy", forType: .string)
        try await Task.sleep(for: .milliseconds(350))
        #expect(recovered.isEmpty)
        #expect(board.string(forType: .string) == "next copy")

        // Two no-op native copies can share a change count; the latest click wins.
        let secondURL = try #require(URL(string: "https://image.example/second.svg"))
        action.copyImage(item)
        action.imageURL = secondURL
        action.copyImage(item)
        try await Task.sleep(for: .milliseconds(350))
        #expect(recovered == [secondURL])
    }

    @Test func imageCopyMenuKeepsOtherCopyActionsAndUsesLatestTrustedImage() throws {
        let view = makeView()
        defer { view.invalidateContextMenu() }
        let menu = NSMenu()
        let spy = ImageCopySpy()
        let image = menu.addItem(withTitle: "复制图像", action: #selector(ImageCopySpy.copy(_:)), keyEquivalent: "")
        image.target = spy
        let link = menu.addItem(withTitle: "Copy Link", action: #selector(ImageCopySpy.copy(_:)), keyEquivalent: "")
        link.target = spy
        let copy = menu.addItem(withTitle: "Copy", action: #selector(ImageCopySpy.copy(_:)), keyEquivalent: "")
        copy.target = spy
        let subject = menu.addItem(withTitle: "Copy Subject", action: #selector(ImageCopySpy.copy(_:)), keyEquivalent: "")
        subject.target = spy
        view.rewriteImageCopyItems(in: menu, imageURL: nil, nativeTitle: "复制图像")
        let target = try #require(image.target as? BrowserWebView.ImageCopyAction)
        let latest = try #require(URL(string: "https://image.example/current.svg"))
        view.rewriteImageCopyItems(in: menu, imageURL: latest)
        #expect(image.target === target)
        #expect(target.imageURL == latest)
        #expect(link.target === spy && copy.target === spy && subject.target === spy)
        #expect(link.representedObject == nil && copy.representedObject == nil && subject.representedObject == nil)
        view.invalidateContextMenu()
        try invoke(image)
        #expect(spy.calls == 0)
    }

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
        #expect(services.items.map(\.title) == ["Open man Page in Terminal", "Ask Claude"])
        let webpage = NSMenu()
        webpage.addItem(withTitle: "Search with Google", action: nil, keyEquivalent: "")
        webpage.addItem(withTitle: "Open with Safari", action: nil, keyEquivalent: "")
        webpage.addItem(withTitle: "Open with Preview", action: nil, keyEquivalent: "")
        BrowserWebView.removeExternalBrowserItems(in: webpage)
        #expect(webpage.items.map(\.title) == ["Search with Google", "Open with Preview"])
    }

    @Test func topLevelServicesCannotOpenAWebsiteThroughFinder() {
        let mainMenu = NSMenu(title: "Main")
        let appMenu = NSMenu(title: "Nous Browser")
        let app = mainMenu.addItem(withTitle: "Nous Browser", action: nil, keyEquivalent: "")
        app.submenu = appMenu
        let services = NSMenu(title: "Services")
        appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        for title in ["打开", "打开 URL", "添加到阅读列表", "在 Finder 中显示", "词典查询"] {
            services.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
        let fileMenu = NSMenu(title: "File")
        mainMenu.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = fileMenu
        fileMenu.addItem(withTitle: "打开", action: nil, keyEquivalent: "")

        BrowserWebView.removeExternalBrowserItems(in: mainMenu, nativeOpenURLTitle: "打开 URL",
                                                  nativeReadingListTitle: "添加到阅读列表", nativeOpenTitle: "打开")
        #expect(services.items.map(\.title) == ["在 Finder 中显示", "词典查询"])
        #expect(fileMenu.items.map(\.title) == ["打开"])
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
        #expect(configuration.userContentController.userScripts.count == 3)
        #expect(configuration.userContentController.userScripts.filter {
            $0.source.contains("nous-browser-slides-ime-return-v1")
        }.count == 1)
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
            matches(selector) { return selector === 'a[href], area[href]' && this.href !== null; }
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

    @Test func downloadMessagesValidateFrameOriginsSchemesAndFilenames() throws {
        let body: [String: Any] = [
            "documentURL": "https://frame.example:8443/page",
            "href": "https://cdn.example/file.pdf", "downloadFilename": "../report.pdf",
            "imageURL": "data:image/png;base64,cGljdHVyZQ==",
            "videoURL": "blob:https://frame.example:8443/fixture-id",
            "audioURL": "https://media.example/track.m4a"
        ]
        let requests = BrowserWebView.downloadRequests(from: body, frameScheme: "https", frameHost: "frame.example", framePort: 8443)
        #expect(requests.count == 4)
        #expect(requests[.link]?.suggestedFilename == "report.pdf")
        #expect(requests[.video]?.url.absoluteString == body["videoURL"] as? String)
        #expect(requests[.image]?.url.scheme == "data")
        #expect(BrowserWebView.downloadRequests(from: body, frameScheme: "https", frameHost: "top.example", framePort: 8443).isEmpty)
        #expect(BrowserWebView.downloadRequests(from: body, frameScheme: "https", frameHost: "frame.example", framePort: 443).isEmpty)
        for value in ["file:///private/test", "javascript:alert(1)", "mailto:test@example.test", "https://user:password@example.test/file",
                      "/relative.mp4", "blob:https://different.example/fixture-id", "blob:https://frame.example/fixture-id",
                      "data:missing-comma", "data:text/plain," + String(repeating: "x", count: 2 * 1024 * 1024)] {
            let invalid: [String: Any] = ["documentURL": "https://frame.example:8443/page", "videoURL": value]
            #expect(BrowserWebView.downloadRequests(from: invalid, frameScheme: "https", frameHost: "frame.example", framePort: 8443).isEmpty)
        }
    }

    @Test func nativeDownloadsUseTheirOwnResourceAndPreserveOtherMenuActions() throws {
        let view = makeView()
        defer { view.invalidateContextMenu() }
        let menu = NSMenu()
        let native = NativeActionSpy()
        let kinds: [(String, BrowserWebView.DownloadKind)] = [("Download Linked File", .link), ("Download Image", .image),
                                                              ("Download Video", .video), ("Download Audio", .audio)]
        let items = kinds.map { title, _ in menu.addItem(withTitle: title, action: #selector(NativeActionSpy.invoke(_:)), keyEquivalent: "") }
        items.forEach { $0.target = native }
        let videoImage = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)
        items[2].image = videoImage
        let play = menu.addItem(withTitle: "Play", action: #selector(NativeActionSpy.invoke(_:)), keyEquivalent: "")
        play.target = native
        let copy = menu.addItem(withTitle: "Copy Video Address", action: #selector(NativeActionSpy.invoke(_:)), keyEquivalent: "")
        copy.target = native
        var received: [BrowserWebView.DownloadRequest] = []
        view.onDownload = { received.append($0) }
        let requests = Dictionary(uniqueKeysWithValues: kinds.map { _, kind in
            (kind, BrowserWebView.DownloadRequest(url: URL(string: "https://example.test/\(kind.rawValue)")!))
        })
        view.rewriteDownloadItems(in: menu, requests: requests)
        #expect(menu.items == items + [play, copy])
        #expect(items[2].image === videoImage)
        #expect(play.target as? NativeActionSpy === native && copy.target as? NativeActionSpy === native)
        for item in items { try invoke(item) }
        #expect(received == kinds.compactMap { requests[$0.1] })
        #expect(native.calls == 0)
        view.invalidateContextMenu()
        try invoke(items[2])
        #expect(received.count == 4)
    }

    @Test func missingDownloadContextCannotRunNativeActionAndLateMessageEnablesIt() throws {
        let view = makeView()
        defer { view.invalidateContextMenu() }
        let menu = NSMenu()
        let native = NativeActionSpy()
        let item = menu.addItem(withTitle: "Download Video", action: #selector(NativeActionSpy.invoke(_:)), keyEquivalent: "")
        item.target = native
        var received: [BrowserWebView.DownloadRequest] = []
        view.onDownload = { received.append($0) }
        view.rewriteDownloadItems(in: menu, requests: [:])
        #expect(!item.isEnabled)
        #expect(!(try #require(item.target as? NSMenuItemValidation)).validateMenuItem(item))
        try invoke(item)
        #expect(native.calls == 0 && received.isEmpty)
        let first = BrowserWebView.DownloadRequest(url: URL(string: "https://example.test/first.mp4")!)
        let latest = BrowserWebView.DownloadRequest(url: URL(string: "https://example.test/latest.mp4")!)
        view.rewriteDownloadItems(in: menu, requests: [.video: first])
        view.rewriteDownloadItems(in: menu, requests: [.video: latest])
        #expect(item.isEnabled)
        try invoke(item)
        #expect(received == [latest])
    }

    @Test func localizedDownloadTitlesDoNotAlterUnknownNativeItems() throws {
        let view = makeView()
        defer { view.invalidateContextMenu() }
        let menu = NSMenu()
        let video = menu.addItem(withTitle: "下载视频", action: nil, keyEquivalent: "")
        let image = menu.addItem(withTitle: "将图像存储为…", action: nil, keyEquivalent: "")
        let unknown = menu.addItem(withTitle: "Unknown native action", action: nil, keyEquivalent: "")
        let request = BrowserWebView.DownloadRequest(url: URL(string: "https://example.test/asset")!)
        var received: [BrowserWebView.DownloadRequest] = []
        view.onDownload = { received.append($0) }
        view.rewriteDownloadItems(in: menu, requests: [.video: request, .image: request],
                                  nativeTitles: [.video: ["下载视频"], .image: ["将图像存储为…"]])
        try invoke(video)
        try invoke(image)
        #expect(received == [request, request])
        #expect(video.title == "下载视频" && image.title == "将图像存储为…")
        #expect(unknown.action == nil && unknown.target == nil)
    }

    @Test func pageListenerCapturesMediaCurrentSourcesAndAnchorDownloadName() throws {
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        var sent = [], listeners = {};
        class Element {
            constructor(tag, currentSrc, src, attrs = {}) { this.tag = tag; this.currentSrc = currentSrc; this.src = src; this.attrs = attrs; this.baseURI = 'https://frame.example/base/'; }
            matches(selector) { return selector === 'a[href], area[href]' ? this.tag === 'a' : this.tag === selector; }
            getAttribute(name) { return this.attrs[name] ?? null; }
        }
        class URL { constructor(value, base) { this.href = /^(https?:|blob:|data:)/.test(value) ? value : base + value; } }
        var document = { URL: 'https://frame.example/page', addEventListener(name, fn) { listeners[name] = fn; } };
        var window = { getSelection() { return { toString() { return ''; } }; },
            webkit: { messageHandlers: { nousLinkContextMenu: { postMessage(body) { sent.push(body); } } } } };
        """#)
        context.evaluateScript(BrowserWebView.contextMenuSource)
        let result = context.evaluateScript(#"""
        const anchor = new Element('a', null, null, {href: 'asset', download: 'chosen.mp4'});
        const video = new Element('video', 'blob:https://frame.example/clip', 'fallback.mp4');
        const image = new Element('img', 'high-resolution.png', 'fallback.png');
        const audio = new Element('audio', '', 'track.m4a');
        const event = {isTrusted: true, screenX: 1, screenY: 2, composedPath() { return [video, image, audio, anchor]; }};
        listeners.contextmenu({...event, isTrusted: false});
        listeners.contextmenu(event);
        sent;
        """#)
        try #require(context.exception == nil)
        let messages = try #require(result?.toArray() as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["downloadFilename"] as? String == "chosen.mp4")
        #expect(messages[0]["href"] as? String == "https://frame.example/base/asset")
        #expect(messages[0]["videoURL"] as? String == "blob:https://frame.example/clip")
        #expect(messages[0]["imageURL"] as? String == "https://frame.example/base/high-resolution.png")
        #expect(messages[0]["audioURL"] as? String == "https://frame.example/base/track.m4a")
    }

    @Test func trustedMediaControlEventFindsItsHostWithoutSelectingUnrelatedMedia() throws {
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        var sent = [], listeners = {}, hitPoints = [];
        class Element {
            constructor(tag, src) { this.tag = tag; this.currentSrc = src; this.baseURI = 'https://frame.example/'; }
            matches(selector) { return this.tag === selector; }
        }
        class URL { constructor(value) { this.href = value; } }
        const video = new Element('video', 'https://frame.example/clicked.mp4');
        const control = new Element('button');
        control.getRootNode = () => ({host: video});
        var document = { URL: 'https://frame.example/page',
            elementFromPoint(x, y) { hitPoints.push([x, y]); return control; },
            addEventListener(name, fn) { listeners[name] = fn; } };
        var window = { getSelection() { return null; },
            webkit: { messageHandlers: { nousLinkContextMenu: { postMessage(body) { sent.push(body); } } } } };
        """#)
        context.evaluateScript(BrowserWebView.contextMenuSource)
        let result = context.evaluateScript(#"""
        const event = { isTrusted: true, clientX: 120, clientY: 80, screenX: 1, screenY: 2,
            composedPath() { return [control]; } };
        listeners.contextmenu({...event, isTrusted: false});
        listeners.contextmenu(event);
        ({sent, hitPoints});
        """#)
        try #require(context.exception == nil)
        let value = try #require(result?.toDictionary() as? [String: Any])
        let messages = try #require(value["sent"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["videoURL"] as? String == "https://frame.example/clicked.mp4")
        #expect(value["hitPoints"] as? [[Int]] == [[120, 80]])
    }

    @Test func nativeHitTestUsesTheExactPointAndDoesNotSeeThroughOverlaysOrCrossOriginFrames() throws {
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        var hitPoints = [], clicked;
        class URL { constructor(value, base) { this.href = /^(https?:|blob:|data:)/.test(value) ? value : base + value; } }
        class Element {
            constructor(tag, source) { this.tag = tag; this.currentSrc = source; this.baseURI = 'https://page.example/'; }
            matches(selector) { return selector === 'iframe, frame' ? this.tag === 'iframe' : this.tag === selector; }
        }
        var document = { URL: 'https://page.example/', elementFromPoint(x, y) { hitPoints.push([x, y]); return clicked; } };
        var window = { innerWidth: 800, innerHeight: 600 };
        """#)
        context.evaluateScript("function nativeHit(x, y) {\n" + BrowserWebView.downloadHitTestSource + "\n}")
        let result = context.evaluateScript(#"""
        clicked = new Element('video', 'blob:https://page.example/clip');
        const video = nativeHit(0.5, 0.5);
        clicked = new Element('div');
        const overlay = nativeHit(0.5, 0.5);
        clicked = new Element('iframe');
        Object.defineProperty(clicked, 'contentDocument', {get() { throw new Error('cross-origin'); }});
        const crossOrigin = nativeHit(0.5, 0.5);
        ({video, overlay, crossOrigin, hitPoints});
        """#)
        try #require(context.exception == nil)
        let value = try #require(result?.toDictionary() as? [String: Any])
        let video = try #require(value["video"] as? [String: Any])
        #expect(video["videoURL"] as? String == "blob:https://page.example/clip")
        #expect((value["overlay"] as? [String: Any])?["videoURL"] is NSNull)
        #expect((value["crossOrigin"] as? [String: Any])?.isEmpty == true)
        #expect(value["hitPoints"] as? [[Int]] == [[400, 300], [400, 300], [400, 300]])
    }

    @Test func nativeHitTestDescendsSameOriginFramesAndOpenShadowRoots() throws {
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        var childPoint;
        class URL { constructor(value, base) { this.href = /^(https?:|blob:|data:)/.test(value) ? value : base + value; } }
        const image = {currentSrc: 'retina.png', src: 'small.png', baseURI: 'https://page.example/frame/',
            matches(selector) { return selector === 'img'; }};
        const shadow = {matches() { return false; }, shadowRoot: {elementFromPoint() { return image; }}};
        const childDocument = {URL: 'https://page.example/frame/page', elementFromPoint(x, y) { childPoint = [x, y]; return shadow; }};
        const frame = { contentDocument: childDocument, offsetWidth: 200, offsetHeight: 200, clientLeft: 2, clientTop: 2,
            matches(selector) { return selector === 'iframe, frame'; },
            getBoundingClientRect() { return {left: 300, top: 200, width: 200, height: 200}; } };
        var document = {URL: 'https://page.example/', elementFromPoint() { return frame; }};
        var window = {innerWidth: 800, innerHeight: 600};
        """#)
        context.evaluateScript("function nativeHit(x, y) {\n" + BrowserWebView.downloadHitTestSource + "\n}")
        let result = context.evaluateScript("({body: nativeHit(0.5, 0.5), childPoint})")
        try #require(context.exception == nil)
        let value = try #require(result?.toDictionary() as? [String: Any])
        let body = try #require(value["body"] as? [String: Any])
        #expect(value["childPoint"] as? [Int] == [98, 98])
        #expect(body["documentURL"] as? String == "https://page.example/frame/page")
        #expect(body["imageURL"] as? String == "https://page.example/frame/retina.png")
        #expect(BrowserWebView.downloadRequests(from: body, frameScheme: "https", frameHost: "page.example", framePort: 443)[.image] != nil)
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

@MainActor
private final class ImageCopySpy: NSObject {
    var calls = 0
    var representedObject: AnyObject?
    var write: (() -> Void)?
    @objc func copy(_ item: NSMenuItem) {
        calls += 1
        representedObject = item.representedObject as AnyObject?
        write?()
    }
}
