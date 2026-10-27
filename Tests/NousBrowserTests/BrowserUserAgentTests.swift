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

    @Test @MainActor func editorsCompatibilityIsRestrictedToExactGoogleEditorHostsAndPaths() throws {
        let eligible = [
            "https://docs.google.com/spreadsheets", "https://docs.google.com/spreadsheets/",
            "https://DOCS.GOOGLE.COM/spreadsheets/d/fixture/edit?gid=0#gid=0",
            "http://docs.google.com/spreadsheets/u/0/", "https://docs.google.com:443/spreadsheets/d/fixture",
            "http://docs.google.com:80/spreadsheets/d/fixture", "https://sheets.google.com",
            "https://sheets.google.com/", "https://sheets.google.com:443/u/0/",
            "http://SHEETS.GOOGLE.COM:80/",
            "https://docs.google.com/document", "https://docs.google.com/document/",
            "https://DOCS.GOOGLE.COM/document/d/fixture/edit?tab=t.0#heading=fixture",
            "http://docs.google.com:80/document/u/1/", "https://docs.google.com:443/document/create",
            "https://docs.google.com/presentation", "https://docs.google.com/presentation/",
            "https://docs.google.com/presentation/d/fixture/edit#slide=id.fixture",
            "https://docs.google.com/presentation/u/0/", "https://slides.google.com",
            "https://slides.google.com/", "https://slides.google.com:443/u/0/",
            "http://SLIDES.GOOGLE.COM:80/"
        ]
        for address in eligible {
            let url = try #require(URL(string: address))
            #expect(BrowserUserAgent.needsGoogleEditorsCompatibility(url, supportsModernEditors: true))
            #expect(!BrowserUserAgent.needsGoogleSearchCompatibility(url))
        }
        let native = [
            "https://docs.google.com/", "https://docs.google.com/forms/d/fixture",
            "https://docs.google.com/drawings/d/fixture", "https://docs.google.com/spreadsheet",
            "https://docs.google.com/documents", "https://docs.google.com/presentations",
            "https://docs.google.com/document-other", "https://docs.google.com/presentation-other",
            "https://docs.google.com/Document/d/fixture", "https://docs.google.com/Presentation/d/fixture",
            "https://docs.google.com/document%2Fd/fixture", "https://docs.google.com/%64ocument/d/fixture",
            "https://docs.google.com/presentation%2Fd/fixture", "https://docs.google.com/%70resentation/d/fixture",
            "https://docs.google.com/document/%2e%2e/forms/fixture",
            "https://docs.google.com/presentation/%2e/forms/fixture",
            "https://docs.google.com/spreadsheets-other", "https://docs.google.com/Spreadsheets/d/fixture",
            "https://docs.google.com/spreadsheets%2Fd/fixture", "https://docs.google.com/%73preadsheets/d/fixture",
            "https://docs.google.com.evil.test/spreadsheets/d/fixture", "https://sub.docs.google.com/spreadsheets/",
            "https://sheets.google.com.evil.test/", "https://www.sheets.google.com/",
            "https://slides.google.com.evil.test/", "https://www.slides.google.com/",
            "https://sub.docs.google.com/document/", "https://docs.google.com.evil.test/presentation/",
            "https://accounts.google.com/", "https://drive.google.com/", "https://google.com/search",
            "https://fixture:fixture@docs.google.com/spreadsheets/d/fixture", "https://fixture@sheets.google.com/",
            "https://fixture:fixture@docs.google.com/document/d/fixture", "https://fixture@slides.google.com/",
            "https://docs.google.com:8443/spreadsheets/", "https://docs.google.com:80/spreadsheets/",
            "http://docs.google.com:443/spreadsheets/", "https://sheets.google.com:8443/",
            "https://slides.google.com:80/", "http://slides.google.com:443/", "https://slides.google.com:8443/",
            "https://docs.google.com:8443/document/", "https://docs.google.com:80/presentation/",
            "ftp://slides.google.com/", "file://docs.google.com/document/",
            "ftp://sheets.google.com/", "file://docs.google.com/spreadsheets/", "about:blank",
            "//docs.google.com/spreadsheets/d/fixture", "/spreadsheets/d/fixture"
        ]
        for address in native {
            #expect(!BrowserUserAgent.needsGoogleEditorsCompatibility(try #require(URL(string: address)), supportsModernEditors: true))
        }
        for malformed in ["https://", "https://docs.google.com:invalid/spreadsheets/", ""] {
            #expect(!BrowserUserAgent.needsGoogleEditorsCompatibility(URL(string: malformed), supportsModernEditors: true))
        }
        #expect(!BrowserUserAgent.needsGoogleEditorsCompatibility(nil, supportsModernEditors: true))
    }

    @Test @MainActor func editorsCompatibilityRequiresTheModernSystemCapabilityWhileSearchRemainsAvailable() throws {
        let expectedEditorsCompatibility: Bool
        if #available(macOS 26.4, *) { expectedEditorsCompatibility = true }
        else { expectedEditorsCompatibility = false }
        #expect(BrowserUserAgent.supportsModernGoogleEditorsCompatibility == expectedEditorsCompatibility)
        for address in ["https://docs.google.com/spreadsheets/d/fixture", "https://sheets.google.com/",
                        "https://docs.google.com/document/d/fixture", "https://docs.google.com/presentation/d/fixture",
                        "https://slides.google.com/"] {
            let url = try #require(URL(string: address))
            #expect(!BrowserUserAgent.needsGoogleEditorsCompatibility(url, supportsModernEditors: false))
            #expect(BrowserUserAgent.needsGoogleEditorsCompatibility(url) == expectedEditorsCompatibility)
            #expect(BrowserUserAgent.needsGoogleCompatibility(url) == expectedEditorsCompatibility)
        }
        let search = try #require(URL(string: "https://google.com/search?q=fixture"))
        #expect(BrowserUserAgent.needsGoogleSearchCompatibility(search))
        #expect(BrowserUserAgent.needsGoogleCompatibility(search))
        let account = try #require(URL(string: "https://accounts.google.com/"))
        #expect(!BrowserUserAgent.needsGoogleCompatibility(account))
    }

    @Test @MainActor func compatibilityIdentityKeepsTheNativePlatformAndEngine() throws {
        let configuration = WKWebViewConfiguration()
        BrowserUserAgent.configure(configuration)
        let token = try #require(configuration.applicationNameForUserAgent)
        let prefix = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/620.1.23 (KHTML, like Gecko)"
        let result = try #require(BrowserUserAgent.googleCompatibilityUserAgent(from: prefix + " " + token))
        let expectedVersion: String
        if #available(macOS 26.4, *) { expectedVersion = "26.4" }
        else { expectedVersion = "26.0" }
        #expect(result == prefix + " Version/\(expectedVersion) Safari/620.1.23 " + token)
        #expect(result.components(separatedBy: "NousBrowser/").count == 2)
        #expect(BrowserUserAgent.googleCompatibilityUserAgent(from: prefix) == result)
        for invalid in ["Mozilla/5.0", "AppleWebKit/", "AppleWebKit/620.1beta", "AppleWebKit/620/1"] {
            #expect(BrowserUserAgent.googleCompatibilityUserAgent(from: invalid) == nil)
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

    @Test @MainActor func cachedIdentityAppliesToSearchAndSupportedEditorsSynchronouslyAndNativePagesClearIt() {
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
        for address in ["https://docs.google.com/spreadsheets/d/fixture",
                        "https://docs.google.com/document/d/fixture",
                        "https://docs.google.com/presentation/d/fixture"] {
            let previousCount = decisions.count
            policy.prepare(for: URL(string: address)!) { decisions.append($0) }
            #expect(decisions.count == previousCount + 1 && decisions.last == true)
            if #available(macOS 26.4, *) { #expect(webView.customUserAgent == "Fixture Search UA") }
            else { #expect((webView.customUserAgent ?? "").isEmpty) }
        }
        policy.prepare(for: URL(string: "https://accounts.google.com/")!) { decisions.append($0) }
        #expect(decisions == [true, true, true, true, true])
        #expect((webView.customUserAgent ?? "").isEmpty)
        policy.applyKnownIdentity(for: URL(string: "https://google.com/webhp")!)
        #expect(webView.customUserAgent == "Fixture Search UA")
        for address in ["https://sheets.google.com/", "https://slides.google.com/",
                        "https://docs.google.com/document/d/fixture"] {
            policy.applyKnownIdentity(for: URL(string: address)!)
            if #available(macOS 26.4, *) { #expect(webView.customUserAgent == "Fixture Search UA") }
            else { #expect((webView.customUserAgent ?? "").isEmpty) }
        }
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
        policy.prepare(for: URL(string: "https://accounts.google.com/")!) { decisions.append($0) }
        #expect(decisions == [true])
        #expect((webView.customUserAgent ?? "").isEmpty)
        #expect(resolverCalls == 0)
    }

    @Test(arguments: ["document", "presentation", "spreadsheets"])
    @MainActor func coldEditorNavigationResolvesIdentityAndKeepsItAcrossEditorSwitches(path: String) async {
        guard #available(macOS 26.4, *) else { return }
        let webView = makeWebView()
        let deferred = DeferredAgent()
        var resolverCalls = 0
        let policy = BrowserUserAgent.NavigationPolicy(webView: webView, cachedCompatibilityUserAgent: nil) {
            resolverCalls += 1
            return await deferred.resolve()
        }
        var decisions: [Bool] = []
        policy.prepare(for: URL(string: "https://docs.google.com/\(path)/d/fixture")!) { decisions.append($0) }
        #expect(decisions.isEmpty)
        await deferred.waitUntilStarted()
        deferred.finish("Resolved Editor UA")
        await deferred.waitUntilReturned()
        #expect(decisions == [true])
        #expect(webView.customUserAgent == "Resolved Editor UA")

        for destination in ["document", "presentation", "spreadsheets"] {
            policy.prepare(for: URL(string: "https://docs.google.com/\(destination)/d/fixture")!) { decisions.append($0) }
            #expect(webView.customUserAgent == "Resolved Editor UA")
        }
        #expect(decisions == [true, true, true, true])
        #expect(resolverCalls == 1)
        policy.prepare(for: URL(string: "https://accounts.google.com/")!) { decisions.append($0) }
        #expect(decisions == [true, true, true, true, true])
        #expect((webView.customUserAgent ?? "").isEmpty)
    }

    @Test @MainActor func realWebKitProbeIsVisibleToDocsAndSlidesAndClearsForOtherSites() async throws {
        guard #available(macOS 26.4, *) else { return }
        let actualCompatibility = try #require(await BrowserUserAgent.compatibilityUserAgent())
        for path in ["document", "presentation"] {
            let webView = makeWebView()
            var resolverCalls = 0
            // A fresh per-tab policy must resolve the real shared probe even
            // when there has not been a preceding Google Search navigation.
            let policy = BrowserUserAgent.NavigationPolicy(webView: webView, cachedCompatibilityUserAgent: nil) {
                resolverCalls += 1
                return await BrowserUserAgent.compatibilityUserAgent()
            }
            let editorURL = try #require(URL(string: "https://docs.google.com/\(path)/d/fixture"))
            let ready = await withCheckedContinuation { continuation in
                policy.prepare(for: editorURL) { continuation.resume(returning: $0) }
            }
            #expect(ready && resolverCalls == 1)
            #expect(webView.customUserAgent == actualCompatibility)
            let editorAgent = try #require(try await webView.evaluateJavaScript("navigator.userAgent") as? String)
            #expect(editorAgent == actualCompatibility)
            #expect(editorAgent.contains("Version/26.4 Safari/"))
            #expect(editorAgent.contains("NousBrowser/"))

            let nativeURL = try #require(URL(string: "https://native.example.test/"))
            policy.prepare(for: nativeURL) { #expect($0) }
            #expect((webView.customUserAgent ?? "").isEmpty)
            // Recreate the document so this checks the navigator used by the
            // next page, rather than a possibly cached prior Navigator object.
            webView.loadHTMLString("<!doctype html><title>Native identity</title>", baseURL: nativeURL)
            for _ in 0..<100 {
                if !webView.isLoading, webView.title == "Native identity" { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(webView.title == "Native identity")
            let nativeAgent = try #require(try await webView.evaluateJavaScript("navigator.userAgent") as? String)
            #expect(nativeAgent.contains("NousBrowser/"))
            #expect(!nativeAgent.contains("Version/") && !nativeAgent.contains("Safari/"))
            webView.stopLoading()
        }
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
        policy.applyKnownIdentity(for: URL(string: "https://accounts.google.com/")!)
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

    @Test(arguments: ["document", "presentation", "spreadsheets"])
    @MainActor func aPendingEditorIdentityCannotRestoreCompatibilityAfterLeavingTheEditor(path: String) async {
        guard #available(macOS 26.4, *) else { return }
        let webView = makeWebView()
        let deferred = DeferredAgent()
        let policy = BrowserUserAgent.NavigationPolicy(webView: webView, cachedCompatibilityUserAgent: nil) {
            await deferred.resolve()
        }
        var decisions: [Bool] = []
        policy.prepare(for: URL(string: "https://docs.google.com/\(path)/d/fixture")!) { decisions.append($0) }
        await deferred.waitUntilStarted()
        policy.prepare(for: URL(string: "https://accounts.google.com/")!) { decisions.append($0) }
        #expect(decisions == [false, true])
        #expect((webView.customUserAgent ?? "").isEmpty)
        deferred.finish("Stale Editor UA")
        await deferred.waitUntilReturned()
        #expect(decisions == [false, true])
        #expect((webView.customUserAgent ?? "").isEmpty)
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
