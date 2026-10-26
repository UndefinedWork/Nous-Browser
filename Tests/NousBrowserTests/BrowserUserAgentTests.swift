import Foundation
import Testing
import WebKit
@testable import NousBrowser

@Suite("Browser compatibility profile")
struct BrowserUserAgentTests {
    @Test @MainActor func preservesProvidedWebsiteDataScriptsAndPreferences() {
        let configuration = WKWebViewConfiguration()
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let scripts = WKUserContentController()
        scripts.addUserScript(WKUserScript(source: "window.popupMarker = true;", injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let preferences = WKPreferences()
        preferences.javaScriptCanOpenWindowsAutomatically = false
        preferences.minimumFontSize = 18
        configuration.websiteDataStore = dataStore
        configuration.userContentController = scripts
        configuration.preferences = preferences
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        BrowserUserAgent.configure(configuration)

        #expect(configuration.websiteDataStore === dataStore)
        #expect(configuration.userContentController === scripts)
        #expect(configuration.preferences === preferences)
        #expect(configuration.userContentController.userScripts.count == 1)
        #expect(configuration.userContentController.userScripts.first?.source == "window.popupMarker = true;")
        #expect(!configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(configuration.preferences.minimumFontSize == 18)
        #expect(!configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    @Test @MainActor func normalAndInheritedPopupConfigurationsKeepOnlyTheNativeApplicationSuffix() throws {
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = "NousBrowser/0.9 Version/25.0 Safari/605.1.15 NousBrowser/0.9"
        BrowserUserAgent.configure(configuration)
        let first = try #require(configuration.applicationNameForUserAgent)

        BrowserUserAgent.configure(configuration)
        let popup = try #require(configuration.copy() as? WKWebViewConfiguration)
        BrowserUserAgent.configure(popup)

        #expect(configuration.applicationNameForUserAgent == first)
        #expect(popup.applicationNameForUserAgent == first)
        let tokens = first.split(separator: " ")
        #expect(tokens.count == 1)
        #expect(tokens.first?.hasPrefix("NousBrowser/") == true)
        #expect(!first.contains("Version/") && !first.contains("Safari/"))
        #expect(!first.contains("Mozilla/") && !first.contains("Chrome/"))
    }

    @Test @MainActor func searchCompatibilityIsRestrictedToExactGoogleSearchEndpoints() throws {
        let eligible = [
            "https://google.com", "https://www.google.com/", "http://google.com/webhp",
            "https://WWW.GOOGLE.COM/search?q=fixture", "https://google.com:443/search",
            "http://www.google.com:80/search?client=fixture#results"
        ]
        for address in eligible {
            #expect(BrowserUserAgent.needsGoogleSearchCompatibility(try #require(URL(string: address))))
        }
        let native = [
            "https://docs.google.com/spreadsheets/d/fixture", "https://sheets.google.com/",
            "https://accounts.google.com/", "https://drive.google.com/", "https://mail.google.com/",
            "https://www.google.com/maps", "https://google.com/searching", "https://google.com/search/",
            "https://google.co.uk/search", "https://www.google.com.evil.test/search",
            "https://evilgoogle.com/search", "https://fixture:fixture@google.com/search",
            "https://google.com:8443/search", "https://google.com:80/search", "http://google.com:443/search",
            "file:///search", "about:blank"
        ]
        for address in native {
            #expect(!BrowserUserAgent.needsGoogleSearchCompatibility(try #require(URL(string: address))))
        }
        #expect(!BrowserUserAgent.needsGoogleSearchCompatibility(nil))
    }

    @Test @MainActor func compatibilityIdentityKeepsTheNativePlatformAndEngine() throws {
        let configuration = WKWebViewConfiguration()
        BrowserUserAgent.configure(configuration)
        let token = try #require(configuration.applicationNameForUserAgent)
        let prefix = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/620.1.23 (KHTML, like Gecko)"
        let result = try #require(BrowserUserAgent.googleSearchUserAgent(from: prefix + " " + token))
        #expect(result == prefix + " Version/26.0 Safari/620.1.23 " + token)
        #expect(result.components(separatedBy: "NousBrowser/").count == 2)
        #expect(BrowserUserAgent.googleSearchUserAgent(from: prefix) == result)
        for invalid in ["Mozilla/5.0", "AppleWebKit/", "AppleWebKit/620.1beta", "AppleWebKit/620/1"] {
            #expect(BrowserUserAgent.googleSearchUserAgent(from: invalid) == nil)
        }
    }

    // WebKit can normalize a nil-assigned Cocoa string property to "" on readback.
    // Native-profile assertions accept either representation of a cleared override.
    @MainActor private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        BrowserUserAgent.configure(configuration)
        return WKWebView(frame: .zero, configuration: configuration)
    }

    @MainActor private final class DeferredAgent {
        private var pending: CheckedContinuation<String?, Never>?
        private var startedWaiter: CheckedContinuation<Void, Never>?
        private var returnedWaiter: CheckedContinuation<Void, Never>?
        private var started = false
        private var returned = false

        func resolve() async -> String? {
            started = true
            startedWaiter?.resume()
            startedWaiter = nil
            let result = await withCheckedContinuation { pending = $0 }
            returned = true
            returnedWaiter?.resume()
            returnedWaiter = nil
            return result
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startedWaiter = $0 }
        }

        func waitUntilReturned() async {
            if returned { return }
            await withCheckedContinuation { returnedWaiter = $0 }
        }

        func finish(_ value: String?) {
            let continuation = pending
            pending = nil
            continuation?.resume(returning: value)
        }
    }

    @Test @MainActor func cachedSearchIdentityAppliesSynchronouslyAndNativePagesClearIt() {
        let webView = makeWebView()
        var resolverCalls = 0
        let policy = BrowserUserAgent.NavigationPolicy(webView: webView, cachedCompatibilityUserAgent: "Fixture Search UA") {
            resolverCalls += 1
            return "Unexpected async UA"
        }
        var decisions: [Bool] = []
        policy.prepare(for: URL(string: "https://www.google.com/search?q=fixture")!) { decisions.append($0) }
        #expect(decisions == [true])
        #expect(webView.customUserAgent == "Fixture Search UA")
        policy.prepare(for: URL(string: "https://docs.google.com/spreadsheets/d/fixture")!) { decisions.append($0) }
        #expect(decisions == [true, true])
        #expect((webView.customUserAgent ?? "").isEmpty)
        policy.applyKnownIdentity(for: URL(string: "https://google.com/webhp")!)
        #expect(webView.customUserAgent == "Fixture Search UA")
        policy.applyKnownIdentity(for: URL(string: "https://accounts.google.com/")!)
        #expect((webView.customUserAgent ?? "").isEmpty)
        #expect(resolverCalls == 0)
    }

    @Test @MainActor func unresolvedNativeNavigationNeverStartsACompatibilityProbe() {
        let webView = makeWebView()
        webView.customUserAgent = "Previous Search UA"
        var resolverCalls = 0
        let policy = BrowserUserAgent.NavigationPolicy(webView: webView, cachedCompatibilityUserAgent: nil) {
            resolverCalls += 1
            return "Unexpected UA"
        }
        var decisions: [Bool] = []
        policy.prepare(for: URL(string: "https://docs.google.com/spreadsheets/d/fixture")!) { decisions.append($0) }
        #expect(decisions == [true])
        #expect((webView.customUserAgent ?? "").isEmpty)
        #expect(resolverCalls == 0)
    }

    @Test @MainActor func resolvedSearchIdentityIsReusedByLaterSearchDecisions() async {
        let webView = makeWebView()
        let deferred = DeferredAgent()
        var resolverCalls = 0
        let policy = BrowserUserAgent.NavigationPolicy(webView: webView, cachedCompatibilityUserAgent: nil) {
            resolverCalls += 1
            return await deferred.resolve()
        }
        var decisions: [Bool] = []
        policy.prepare(for: URL(string: "https://google.com/search?q=first")!) { decisions.append($0) }
        #expect(decisions.isEmpty)
        await deferred.waitUntilStarted()
        deferred.finish("Resolved Search UA")
        await deferred.waitUntilReturned()
        #expect(decisions == [true])
        #expect(webView.customUserAgent == "Resolved Search UA")
        policy.prepare(for: URL(string: "https://google.com/search?q=second")!) { decisions.append($0) }
        #expect(decisions == [true, true])
        #expect(resolverCalls == 1)
    }

    @Test @MainActor func changingToANativePageCancelsPendingSearchAndRejectsItsLateResult() async {
        let webView = makeWebView()
        let deferred = DeferredAgent()
        let policy = BrowserUserAgent.NavigationPolicy(webView: webView, cachedCompatibilityUserAgent: nil) {
            await deferred.resolve()
        }
        var decisions: [Bool] = []
        policy.prepare(for: URL(string: "https://google.com/search?q=fixture")!) { decisions.append($0) }
        await deferred.waitUntilStarted()
        policy.applyKnownIdentity(for: URL(string: "https://docs.google.com/spreadsheets/d/fixture")!)
        #expect(decisions == [false])
        #expect((webView.customUserAgent ?? "").isEmpty)
        deferred.finish("Stale Safari UA")
        await deferred.waitUntilReturned()
        #expect(decisions == [false])
        #expect((webView.customUserAgent ?? "").isEmpty)
        policy.invalidate()
        #expect(decisions == [false])
    }

    @Test @MainActor func anOlderAsyncDecisionCannotOverwriteANewerSearchIdentity() async {
        let webView = makeWebView()
        let old = DeferredAgent(), current = DeferredAgent()
        var calls = 0
        let policy = BrowserUserAgent.NavigationPolicy(webView: webView, cachedCompatibilityUserAgent: nil) {
            calls += 1
            return await (calls == 1 ? old : current).resolve()
        }
        var first: [Bool] = [], second: [Bool] = []
        policy.prepare(for: URL(string: "https://google.com/search?q=old")!) { first.append($0) }
        await old.waitUntilStarted()
        policy.prepare(for: URL(string: "https://google.com/search?q=current")!) { second.append($0) }
        await current.waitUntilStarted()
        #expect(first == [false])
        current.finish("Current Search UA")
        await current.waitUntilReturned()
        #expect(second == [true])
        #expect(webView.customUserAgent == "Current Search UA")
        old.finish("Stale Search UA")
        await old.waitUntilReturned()
        #expect(first == [false] && second == [true])
        #expect(webView.customUserAgent == "Current Search UA")
    }

    @Test @MainActor func anUnavailableCompatibilityIdentityAllowsNavigationWithNativeIdentity() async {
        let webView = makeWebView()
        let deferred = DeferredAgent()
        let policy = BrowserUserAgent.NavigationPolicy(webView: webView, cachedCompatibilityUserAgent: nil) {
            await deferred.resolve()
        }
        var decisions: [Bool] = []
        policy.prepare(for: URL(string: "https://google.com/search?q=fixture")!) { decisions.append($0) }
        await deferred.waitUntilStarted()
        deferred.finish(nil)
        await deferred.waitUntilReturned()
        #expect(decisions == [true])
        #expect((webView.customUserAgent ?? "").isEmpty)
    }
}
