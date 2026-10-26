import Foundation
import Testing
import WebKit
@testable import NousBrowser

@Suite("Selection search stays in Nous", .serialized)
@MainActor
struct BrowserSelectionSearchTests {
    @Test func controllerSearchPreferencesDriveAdjacentSearchTabs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaultsDomain = "NousBrowserSelectionSearch-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        let preferences = BrowserPreferences(defaults: defaults)
        let model = BrowserModel(sessionURL: directory.appendingPathComponent("session.json"), restoreSession: false,
                                 loadSelectedTab: false, startWithBlankTab: true)
        let controller = BrowserController(model: model, preferences: preferences)
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: defaultsDomain)
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try #require(model.selectedTab)
        let view = try #require(source.webView as? BrowserWebView)
        model.newTab()
        let following = try #require(model.selectedTabID)
        #expect(model.searchEngineProvider() == .google)
        controller.preferences.selectSearchEngine(.duckDuckGo)
        #expect(view.searchEngineTitle?() == BrowserSearchEngine.duckDuckGo.title)
        let query = "C++ 中文 & test"
        view.onSearchSelection?(query)
        let result = try #require(model.selectedTab)
        result.webView.stopLoading()
        #expect(model.tabs.map(\.id) == [source.id, result.id, following])
        #expect(result.url == BrowserSearchEngine.duckDuckGo.searchURL(query: query))
        #expect(URLComponents(url: try #require(result.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value == query)
        controller.preferences.selectSearchEngine(.bing)
        #expect(view.searchEngineTitle?() == BrowserSearchEngine.bing.title)
        view.onSearchSelection?("Updated default")
        let updated = try #require(model.selectedTab)
        updated.webView.stopLoading()
        #expect(model.tabs.map(\.id) == [source.id, updated.id, result.id, following])
        #expect(updated.url == BrowserSearchEngine.bing.searchURL(query: "Updated default"))
    }

    @Test func transferredPagesUseTheDestinationSearchEngineAndTabList() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = BrowserModel(sessionURL: directory.appendingPathComponent("source.json"), restoreSession: false,
                                  loadSelectedTab: false, startWithBlankTab: true)
        let destination = BrowserModel(sessionURL: directory.appendingPathComponent("destination.json"), restoreSession: false,
                                       loadSelectedTab: false, startWithBlankTab: true)
        defer {
            source.shutdown()
            destination.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        source.searchEngineProvider = { .google }
        destination.searchEngineProvider = { .baidu }
        let moving = try #require(source.selectedTab)
        let view = try #require(moving.webView as? BrowserWebView)
        let existing = try #require(destination.selectedTabID)
        #expect(source.takeTabForTransfer(moving.id) === moving)
        #expect(destination.adoptTransferredTab(moving, at: 0))
        #expect(view.searchEngineTitle?() == BrowserSearchEngine.baidu.title)
        view.onSearchSelection?("Moved selection")
        let result = try #require(destination.selectedTab)
        result.webView.stopLoading()
        #expect(source.tabs.isEmpty)
        #expect(destination.tabs.map(\.id) == [moving.id, result.id, existing])
        #expect(result.url == BrowserSearchEngine.baidu.searchURL(query: "Moved selection"))
    }
}

@Suite("Browser address handling")
struct BrowserAddressTests {
    @Test func resolvesWebAddresses() {
        #expect(BrowserModel.normalizeAddress("apple.com")?.absoluteString == "https://apple.com")
        #expect(BrowserModel.normalizeAddress("  https://example.com/path?q=1  ")?.absoluteString == "https://example.com/path?q=1")
        #expect(BrowserModel.normalizeAddress("localhost:8080/test")?.absoluteString == "http://localhost:8080/test")
        #expect(BrowserModel.normalizeAddress("127.0.0.1:4000")?.absoluteString == "http://127.0.0.1:4000")
    }

    @Test func encodesSearchTermsWithoutChangingMeaning() {
        let url = BrowserModel.normalizeAddress("light browsers & macOS")!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(components.host == "www.google.com")
        #expect(components.queryItems?.first?.value == "light browsers & macOS")
    }

    @Test func rejectsActiveContentAndEmptyInputs() {
        #expect(BrowserModel.normalizeAddress(" \n ") == nil)
        #expect(BrowserModel.normalizeAddress("javascript:alert(1)") == nil)
        #expect(BrowserModel.normalizeAddress("file:///etc/passwd") == nil)
        #expect(BrowserModel.normalizeAddress("data:text/html,test") == nil)
        #expect(BrowserModel.normalizeAddress("https://") == nil)
    }
}

@Suite("Session restoration")
struct BrowserSessionTests {
    @Test @MainActor func restoresOlderSessionsWithoutDiscardingTabs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("session.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = UUID()
        let selected = UUID()
        let legacySession: [String: Any] = [
            "tabs": [
                ["id": first.uuidString, "title": "Saved website", "url": "https://example.com/account"],
                ["id": selected.uuidString, "title": "新标签页"]
            ],
            "selectedTabID": selected.uuidString,
            "isSidebarVisible": false
        ]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: legacySession)
        try data.write(to: file)
        let decoded = try JSONDecoder().decode(BrowserSession.self, from: data)
        #expect(decoded.sidebarWidth == SidebarSizing.defaultWidth)
        let restored = BrowserModel(sessionURL: file, loadSelectedTab: false)
        #expect(restored.tabs.map(\.id) == [first, selected])
        #expect(restored.tabs.first?.url?.absoluteString == "https://example.com/account")
        #expect(restored.selectedTabID == selected)
        #expect(!restored.isSidebarVisible)
        #expect(restored.sidebarWidth == SidebarSizing.defaultWidth)
    }

    @Test @MainActor func savesPreferredSidebarWidthAcrossRestarts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("session.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = BrowserModel(sessionURL: file, restoreSession: false, loadSelectedTab: false)
        browser.resizeSidebar(to: 356)
        browser.persistSession()
        let restored = BrowserModel(sessionURL: file, loadSelectedTab: false)
        #expect(restored.sidebarWidth == 356)
        #expect(restored.tabs.map(\.id) == browser.tabs.map(\.id))
        restored.resetSidebarWidth()
        restored.persistSession()
        let reset = BrowserModel(sessionURL: file, loadSelectedTab: false)
        #expect(reset.sidebarWidth == SidebarSizing.defaultWidth)
    }

    @Test @MainActor func clampsOutOfRangeSavedSidebarWidth() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("session.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let session = BrowserSession(tabs: [.init(id: id, title: "Saved", url: nil)], selectedTabID: id, isSidebarVisible: true, sidebarWidth: 9_000)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(session).write(to: file)
        let restored = BrowserModel(sessionURL: file, loadSelectedTab: false)
        #expect(restored.sidebarWidth == SidebarSizing.maximumWidth)
        #expect(restored.selectedTabID == id)
    }

    @Test @MainActor func restoresSelectionSidebarAndLazyTabs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("session.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = BrowserModel(sessionURL: file, restoreSession: false, loadSelectedTab: false)
        browser.newTab()
        let selected = browser.selectedTabID
        browser.isSidebarVisible = false
        browser.persistSession()
        let restored = BrowserModel(sessionURL: file, loadSelectedTab: false)
        #expect(restored.tabs.count == 2)
        #expect(restored.selectedTabID == selected)
        #expect(!restored.isSidebarVisible)
        #expect(restored.tabs.allSatisfy { $0.webView.url == nil })
        #expect(restored.tabs.first?.url?.host == "www.apple.com")
        #expect(restored.selectedTab?.url == nil)
    }

    @Test @MainActor func closeLastTabLeavesAUsableBlankTabAndCanRestore() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let browser = BrowserModel(sessionURL: file, restoreSession: false, loadSelectedTab: false)
        let initialID = browser.selectedTabID!
        browser.newTab()
        browser.closeTab(initialID)
        let firstID = browser.selectedTabID!
        browser.closeTab(firstID)
        #expect(browser.tabs.count == 1)
        #expect(browser.selectedTab?.url == nil)
        #expect(browser.selectedTabID != firstID)
        browser.restoreClosedTab()
        #expect(browser.tabs.count == 2)
        #expect(browser.selectedTabID == firstID)
    }

    @Test @MainActor func storesNoEmbeddedUsernameOrPassword() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("session.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let session = BrowserSession(tabs: [.init(id: id, title: "Example", url: URL(string: "https://username:password@example.com/path"))], selectedTabID: id, isSidebarVisible: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(session).write(to: file)
        let browser = BrowserModel(sessionURL: file, loadSelectedTab: false)
        browser.persistSession()
        let stored = try JSONDecoder().decode(BrowserSession.self, from: Data(contentsOf: file))
        #expect(stored.tabs[0].url?.user == nil)
        #expect(stored.tabs[0].url?.password == nil)
        #expect(stored.tabs[0].url?.host == "example.com")
    }
}

@Suite("Sidebar sizing")
struct SidebarSizingTests {
    @Test func boundsPreferredWidthAndRejectsNonfiniteValues() {
        #expect(SidebarSizing.clampedWidth(-100) == 180)
        #expect(SidebarSizing.clampedWidth(0) == 180)
        #expect(SidebarSizing.clampedWidth(300) == 300)
        #expect(SidebarSizing.clampedWidth(10_000) == 420)
        #expect(SidebarSizing.clampedWidth(.nan) == 243)
        #expect(SidebarSizing.clampedWidth(.infinity) == 243)
        #expect(SidebarSizing.clampedWidth(-.infinity) == 243)
    }

    @Test func preservesPageSpaceInNarrowWindows() {
        #expect(SidebarSizing.effectiveWidth(preferred: 360, windowWidth: 900) == 360)
        #expect(SidebarSizing.effectiveWidth(preferred: 360, windowWidth: 600) == 280)
        #expect(SidebarSizing.effectiveWidth(preferred: 360, windowWidth: 500) == 180)
        #expect(SidebarSizing.effectiveWidth(preferred: 360, windowWidth: 400) == 180)
        #expect(SidebarSizing.effectiveWidth(preferred: 9_000, windowWidth: 1_000) == 420)
        #expect(SidebarSizing.effectiveWidth(preferred: .nan, windowWidth: 900) == 243)
        #expect(SidebarSizing.effectiveWidth(preferred: 360, windowWidth: .nan) == 360)
    }
}

@Suite("Safari website wrappers stay in Nous")
struct SafariWebsiteWrapperTests {
    @Test func onlyTheKnownHTTPSWrapperBecomesAnInternalWebsite() throws {
        let wrapped = try #require(URL(string: "x-safari-https://example.com:8443/path?q=C%2B%2B&text=%E4%B8%AD%E6%96%87#section"))
        let website = try #require(BrowserModel.unwrappedSafariWebsite(wrapped))
        #expect(website.absoluteString == "https://example.com:8443/path?q=C%2B%2B&text=%E4%B8%AD%E6%96%87#section")
        for input in ["x-safari-https:///missing-host", "x-safari-https://user:secret@example.com/", "x-safari-http://example.com/", "x-webkit-app-launch://example.com/", "https://example.com/", "mailto:test@example.com"] {
            #expect(BrowserModel.unwrappedSafariWebsite(try #require(URL(string: input))) == nil)
        }
    }
}
