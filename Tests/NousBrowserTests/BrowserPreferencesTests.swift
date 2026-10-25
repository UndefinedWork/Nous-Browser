import Foundation
import Testing
@testable import NousBrowser

@Suite("Browser preferences", .serialized)
@MainActor
struct BrowserPreferencesTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let domain = "NousBrowserPreferencesTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        try body(defaults)
    }

    @Test func missingPreferencesKeepTheOriginalEngineAndFourQuickLinks() {
        withDefaults { defaults in
            let preferences = BrowserPreferences(defaults: defaults)
            #expect(preferences.searchEngine == .google)
            #expect(preferences.quickLinks.map(\.url.absoluteString) == [
                "https://www.apple.com", "https://www.google.com", "https://www.wikipedia.org", "https://chatgpt.com"
            ])
            #expect(Set(preferences.quickLinks.map(\.id)).count == 4)
            #expect(BrowserPreferences(defaults: defaults).quickLinks == preferences.quickLinks)
        }
    }

    @Test func selectingAnEnginePersistsImmediately() {
        withDefaults { defaults in
            let preferences = BrowserPreferences(defaults: defaults)
            for engine in BrowserSearchEngine.allCases {
                preferences.selectSearchEngine(engine)
                #expect(BrowserPreferences(defaults: defaults).searchEngine == engine)
                #expect(preferences.quickLinks == BrowserPreferences.defaultQuickLinks)
            }
        }
    }

    @Test func providerEndpointsPreserveUnicodeAndLiteralSearchPunctuation() throws {
        let query = "C++ & 中文 / ? # % + a=b"
        let cases: [(BrowserSearchEngine, String, String, String)] = [
            (.google, "www.google.com", "/search", "q"),
            (.bing, "www.bing.com", "/search", "q"),
            (.duckDuckGo, "duckduckgo.com", "/", "q"),
            (.baidu, "www.baidu.com", "/s", "wd")
        ]
        for (engine, host, path, parameter) in cases {
            let url = engine.searchURL(query: query)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.scheme == "https")
            #expect(components.host == host)
            #expect(components.path == path)
            #expect(components.queryItems == [URLQueryItem(name: parameter, value: query)])
            #expect(components.percentEncodedQuery?.contains("+") == false)
            #expect(components.percentEncodedQuery?.contains("%2B") == true)
            #expect(components.fragment == nil)
        }
    }

    @Test func addressNormalizationUsesTheEngineOnlyForSearches() throws {
        for engine in BrowserSearchEngine.allCases {
            #expect(BrowserModel.normalizeAddress("two search words", searchEngine: engine) == engine.searchURL(query: "two search words"))
            #expect(BrowserModel.normalizeAddress("example.com/path", searchEngine: engine)?.absoluteString == "https://example.com/path")
            #expect(BrowserModel.normalizeAddress("http://localhost:8765/path", searchEngine: engine)?.absoluteString == "http://localhost:8765/path")
            #expect(BrowserModel.normalizeAddress("javascript:alert(1)", searchEngine: engine) == nil)
        }
        let legacySearch = try #require(BrowserModel.normalizeAddress("original default search"))
        #expect(legacySearch.host == "www.google.com")
    }

    @Test func customLinksTrimTheirNamesAndKeepIdentityWhenEditedAndRestored() throws {
        try withDefaults { defaults in
            let preferences = BrowserPreferences(defaults: defaults)
            let link = try preferences.addQuickLink(title: "  Example 中文 \n", address: "  example.test:8443/path?q=1#part  ")
            #expect(link.title == "Example 中文")
            #expect(link.url.absoluteString == "https://example.test:8443/path?q=1#part")
            #expect(BrowserPreferences(defaults: defaults).quickLinks.last == link)
            try preferences.updateQuickLink(id: link.id, title: " Updated ", address: "http://localhost:8765/other")
            let edited = try #require(preferences.quickLinks.last)
            #expect(edited.id == link.id)
            #expect(edited.title == "Updated")
            #expect(edited.url.absoluteString == "http://localhost:8765/other")
            #expect(preferences.quickLinks.count == 5)
            #expect(BrowserPreferences(defaults: defaults).quickLinks == preferences.quickLinks)
        }
    }

    @Test func invalidNamesAndAddressesLeaveTheSavedListUntouched() throws {
        try withDefaults { defaults in
            let preferences = BrowserPreferences(defaults: defaults)
            let saved = try preferences.addQuickLink(title: "Fixture", address: "https://example.test/")
            let before = preferences.quickLinks
            #expect(throws: BrowserPreferencesError.emptyTitle) {
                try preferences.addQuickLink(title: " \n\t ", address: "https://example.test/")
            }
            for address in ["", "javascript:alert(1)", "javascript:123", "data:text/html,test", "file:///tmp/local.html",
                            "ftp://example.test/", "mailto:user@example.test", "about:blank", "https://", "words with spaces",
                            "https://exa mple.test/", "https://example..test/", "https://-bad.test/", "https://bad-.test/",
                            "https://example.test:65536/", "https://example.test:0/", "https://[:::]/",
                            "https://user:synthetic@example.test/", "https://example.test\\@other.test/", "https://example.test/\nother"] {
                #expect(throws: BrowserPreferencesError.invalidAddress) {
                    try preferences.updateQuickLink(id: saved.id, title: "Fixture", address: address)
                }
            }
            #expect(throws: BrowserPreferencesError.linkNotFound) {
                try preferences.updateQuickLink(id: UUID(), title: "Missing", address: "https://example.test/")
            }
            #expect(preferences.quickLinks == before)
            #expect(BrowserPreferences(defaults: defaults).quickLinks == before)
        }
    }

    @Test func localIPv6AndInternationalHostsAreAcceptedAsWebLinks() throws {
        try withDefaults { defaults in
            let preferences = BrowserPreferences(defaults: defaults)
            let local = try preferences.addQuickLink(title: "IPv6 fixture", address: "[::1]:9443/path")
            #expect(local.url.scheme == "https")
            #expect(local.url.port == 9443)
            let international = try preferences.addQuickLink(title: "International fixture", address: "https://例子.测试/path")
            #expect(international.url.scheme == "https")
            #expect(!((international.url.host ?? "").isEmpty))
        }
    }

    @Test func movingAndRemovingLinksPreservesOrderAndAnIntentionallyEmptyList() {
        withDefaults { defaults in
            let preferences = BrowserPreferences(defaults: defaults)
            let original = preferences.quickLinks
            preferences.moveQuickLink(id: original[0].id, offset: -1)
            preferences.moveQuickLink(id: original[3].id, offset: 1)
            preferences.moveQuickLink(id: original[1].id, offset: 2)
            preferences.moveQuickLink(id: UUID(), offset: 1)
            #expect(preferences.quickLinks == original)
            preferences.moveQuickLink(id: original[1].id, offset: 1)
            #expect(preferences.quickLinks.map(\.id) == [original[0].id, original[2].id, original[1].id, original[3].id])
            #expect(BrowserPreferences(defaults: defaults).quickLinks == preferences.quickLinks)
            for link in original { preferences.removeQuickLink(id: link.id) }
            #expect(preferences.quickLinks.isEmpty)
            #expect(BrowserPreferences(defaults: defaults).quickLinks.isEmpty)
            preferences.selectSearchEngine(.bing)
            preferences.restoreDefaultQuickLinks()
            #expect(preferences.quickLinks == BrowserPreferences.defaultQuickLinks)
            #expect(BrowserPreferences(defaults: defaults).quickLinks == BrowserPreferences.defaultQuickLinks)
            #expect(preferences.searchEngine == .bing)
        }
    }

    @Test func unreadablePreferencesFallBackWhileValidSavedLinksSurviveValidation() throws {
        try withDefaults { defaults in
            defaults.set("unsupported-future-engine", forKey: "browser.searchEngine")
            defaults.set(Data("not JSON".utf8), forKey: "browser.quickLinks")
            let fallback = BrowserPreferences(defaults: defaults)
            #expect(fallback.searchEngine == .google)
            #expect(fallback.quickLinks == BrowserPreferences.defaultQuickLinks)
            let id = UUID()
            let saved = [
                BrowserQuickLink(id: id, title: " Valid fixture ", url: URL(string: "https://example.test/")!),
                BrowserQuickLink(id: id, title: "Duplicate ID", url: URL(string: "https://other.test/")!),
                BrowserQuickLink(title: "Unsafe fixture", url: URL(string: "javascript:alert(1)")!)
            ]
            defaults.set(try JSONEncoder().encode(saved), forKey: "browser.quickLinks")
            let restored = BrowserPreferences(defaults: defaults)
            #expect(restored.quickLinks.count == 1)
            #expect(restored.quickLinks[0].id == id)
            #expect(restored.quickLinks[0].title == "Valid fixture")
            #expect(restored.quickLinks[0].url == saved[0].url)
        }
    }
}
