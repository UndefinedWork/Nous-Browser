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

    @Test @MainActor func workspaceCompatibilityIsRestrictedToExactGoogleAppHostsAndPaths() throws {
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
            "http://SLIDES.GOOGLE.COM:80/",
            "https://mail.google.com", "https://mail.google.com/", "https://mail.google.com/?authuser=1",
            "https://mail.google.com/mail", "https://mail.google.com/mail/",
            "https://MAIL.GOOGLE.COM/mail/u/0/#inbox", "https://mail.google.com/mail/u/1/?ui=2#sent",
            "https://mail.google.com:443/mail/u/0/", "http://mail.google.com:80/mail/"
        ]
        for address in eligible {
            let url = try #require(URL(string: address))
            #expect(BrowserUserAgent.needsGoogleWorkspaceCompatibility(url, supportsModernWorkspace: true))
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
            "https://mail.google.com/chat/", "https://mail.google.com/mailbox", "https://mail.google.com/mail-other",
            "https://mail.google.com/Mail/u/0/", "https://mail.google.com/mail%2Fu/0/",
            "https://mail.google.com/%6dail/u/0/", "https://mail.google.com//mail/u/0/",
            "https://mail.google.com/mail/%2e%2e/chat", "https://mail.google.com/mail/%2e/u/0/",
            "https://mail.google.com.evil.test/mail/", "https://www.mail.google.com/mail/",
            "https://sub.mail.google.com/mail/", "https://gmail.com/", "https://www.gmail.com/",
            "https://accounts.google.com/", "https://drive.google.com/", "https://google.com/search",
            "https://fixture:fixture@docs.google.com/spreadsheets/d/fixture", "https://fixture@sheets.google.com/",
            "https://fixture:fixture@docs.google.com/document/d/fixture", "https://fixture@slides.google.com/",
            "https://docs.google.com:8443/spreadsheets/", "https://docs.google.com:80/spreadsheets/",
            "http://docs.google.com:443/spreadsheets/", "https://sheets.google.com:8443/",
            "https://slides.google.com:80/", "http://slides.google.com:443/", "https://slides.google.com:8443/",
            "https://docs.google.com:8443/document/", "https://docs.google.com:80/presentation/",
            "https://fixture:fixture@mail.google.com/mail/", "https://fixture@mail.google.com/",
            "https://mail.google.com:8443/mail/", "https://mail.google.com:80/mail/", "http://mail.google.com:443/mail/",
            "ftp://mail.google.com/mail/", "file://mail.google.com/mail/", "//mail.google.com/mail/",
            "ftp://slides.google.com/", "file://docs.google.com/document/",
            "ftp://sheets.google.com/", "file://docs.google.com/spreadsheets/", "about:blank",
            "//docs.google.com/spreadsheets/d/fixture", "/spreadsheets/d/fixture"
        ]
        for address in native {
            #expect(!BrowserUserAgent.needsGoogleWorkspaceCompatibility(try #require(URL(string: address)), supportsModernWorkspace: true))
        }
        for malformed in ["https://", "https://docs.google.com:invalid/spreadsheets/", "https://mail.google.com:invalid/mail/", ""] {
            #expect(!BrowserUserAgent.needsGoogleWorkspaceCompatibility(URL(string: malformed), supportsModernWorkspace: true))
        }
        #expect(!BrowserUserAgent.needsGoogleWorkspaceCompatibility(nil, supportsModernWorkspace: true))
    }

    @Test @MainActor func workspaceCompatibilityRequiresTheModernSystemCapabilityWhileSearchRemainsAvailable() throws {
        let expectedWorkspaceCompatibility: Bool
        if #available(macOS 26.4, *) { expectedWorkspaceCompatibility = true }
        else { expectedWorkspaceCompatibility = false }
        #expect(BrowserUserAgent.supportsModernGoogleWorkspaceCompatibility == expectedWorkspaceCompatibility)
        for address in ["https://docs.google.com/spreadsheets/d/fixture", "https://sheets.google.com/",
                        "https://docs.google.com/document/d/fixture", "https://docs.google.com/presentation/d/fixture",
                        "https://slides.google.com/", "https://mail.google.com/", "https://mail.google.com/mail/u/0/"] {
            let url = try #require(URL(string: address))
            #expect(!BrowserUserAgent.needsGoogleWorkspaceCompatibility(url, supportsModernWorkspace: false))
            #expect(BrowserUserAgent.needsGoogleWorkspaceCompatibility(url) == expectedWorkspaceCompatibility)
            #expect(BrowserUserAgent.needsGoogleCompatibility(url) == expectedWorkspaceCompatibility)
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
        let result = try #require(BrowserUserAgent.safariCompatibilityUserAgent(from: prefix + " " + token))
        let expectedVersion: String
        if #available(macOS 26.4, *) { expectedVersion = "26.4" }
        else { expectedVersion = "26.0" }
        #expect(result == prefix + " Version/\(expectedVersion) Safari/620.1.23 " + token)
        #expect(result.components(separatedBy: "NousBrowser/").count == 2)
        #expect(BrowserUserAgent.safariCompatibilityUserAgent(from: prefix) == result)
        for invalid in ["Mozilla/5.0", "AppleWebKit/", "AppleWebKit/620.1beta", "AppleWebKit/620/1"] {
            #expect(BrowserUserAgent.safariCompatibilityUserAgent(from: invalid) == nil)
        }
    }

    @Test @MainActor func zoomSlidesCompatibilityIsRestrictedToVerifiedHTTPSHosts() throws {
        for address in ["https://slides.zoom.us", "https://slides.zoom.us/",
                        "https://SLIDES.ZOOM.US/p/fixture/edit?mode=edit#slide=1",
                        "https://slides.zoom.us:443/d/fixture", "https://slides.zoom.com/",
                        "https://slides.zoom.com:443/p/fixture", "https://present.zoom.us/",
                        "https://dg01slides.zoom.us/p/fixture", "https://us01slides.zoom.us/",
                        "https://eu02slides.zoom.us/", "https://dg01present.zoom.us/"] {
            let url = try #require(URL(string: address))
            #expect(BrowserUserAgent.needsZoomSlidesCompatibility(url))
            #expect(BrowserUserAgent.needsCompatibility(url))
            #expect(!BrowserUserAgent.needsGoogleCompatibility(url))
        }
        for address in ["http://slides.zoom.us/", "http://slides.zoom.com/", "http://present.zoom.us/",
                        "https://slides.zoom.us:80/", "https://slides.zoom.us:8443/",
                        "https://slides.zoom.com:8443/", "https://present.zoom.us:8443/",
                        "https://user@slides.zoom.us/", "https://user:password@slides.zoom.com/",
                        "https://@present.zoom.us/", "https://slides.zoom.us.evil.test/",
                        "https://evilslides.zoom.us/", "https://www.slides.zoom.us/",
                        "https://unknownslides.zoom.us/", "https://slides.zoom.us./",
                        "https://dg01slides.zoom.us.evil.test/", "https://dg01slides.zoom.us:8443/",
                        "https://user@dg01slides.zoom.us/", "http://dg01slides.zoom.us/",
                        "https://zoom.us/signin", "https://zoom.com/", "https://accounts.zoom.us/",
                        "https://docs.zoom.us/", "https://canvas.zoom.us/", "https://sheets.zoom.us/",
                        "https://present.zoom.com/", "https://st1.zoom.us/zoom-docs/",
                        "file://slides.zoom.us/", "ftp://slides.zoom.us/", "//slides.zoom.us/", "about:blank"] {
            let url = try #require(URL(string: address))
            #expect(!BrowserUserAgent.needsZoomSlidesCompatibility(url))
            #expect(!BrowserUserAgent.needsCompatibility(url))
        }
        #expect(!BrowserUserAgent.needsZoomSlidesCompatibility(nil))
        #expect(!BrowserUserAgent.needsCompatibility(nil))
    }

    @Test @MainActor func zoomSlidesAndGoogleTransitionsReuseIdentityAndLeaveOtherZoomSitesNative() async {
        let webView = makeWebView()
        let deferred = DeferredAgent()
        var calls = 0
        let policy = BrowserUserAgent.NavigationPolicy(webView: webView, cachedCompatibilityUserAgent: nil) {
            calls += 1
            return await deferred.resolve()
        }
        var decisions: [Bool] = []
        policy.prepare(for: URL(string: "https://slides.zoom.us/p/fixture")!) { decisions.append($0) }
        #expect(decisions.isEmpty)
        await deferred.waitUntilStarted()
        deferred.finish("Resolved Safari UA")
        await deferred.waitUntilReturned()
        #expect(decisions == [true])
        #expect(webView.customUserAgent == "Resolved Safari UA")
        for (address, compatible) in [
            ("https://www.google.com/search?q=fixture", true),
            ("https://zoom.us/signin", false),
            ("https://slides.zoom.com/", true),
            ("https://accounts.google.com/", false),
            ("https://present.zoom.us/p/fixture", true),
            ("https://docs.google.com/presentation/d/fixture", BrowserUserAgent.supportsModernGoogleWorkspaceCompatibility),
            ("https://docs.zoom.us/doc/fixture", false),
            ("https://slides.zoom.us/p/fixture", true)
        ] {
            policy.prepare(for: URL(string: address)!) { decisions.append($0) }
            #expect(compatible ? webView.customUserAgent == "Resolved Safari UA" : (webView.customUserAgent ?? "").isEmpty)
        }
        #expect(decisions == Array(repeating: true, count: 9))
        #expect(calls == 1)
    }

    @Test @MainActor func zoomPopupKnownIdentityIsScopedAndPendingResultsCannotRestoreItAfterLeaving() async {
        let popup = makeWebView()
        let known = BrowserUserAgent.NavigationPolicy(webView: popup, cachedCompatibilityUserAgent: "Popup Safari UA")
        for address in ["https://slides.zoom.us/p/fixture", "https://slides.zoom.com/", "https://present.zoom.us/"] {
            known.applyKnownIdentity(for: URL(string: address)!)
            #expect(popup.customUserAgent == "Popup Safari UA")
            known.applyKnownIdentity(for: URL(string: "https://zoom.us/signin")!)
            #expect((popup.customUserAgent ?? "").isEmpty)
        }

        let deferred = DeferredAgent()
        let pending = BrowserUserAgent.NavigationPolicy(webView: popup, cachedCompatibilityUserAgent: nil) {
            await deferred.resolve()
        }
        var decisions: [Bool] = []
        pending.prepare(for: URL(string: "https://slides.zoom.us/p/fixture")!) { decisions.append($0) }
        await deferred.waitUntilStarted()
        pending.applyKnownIdentity(for: URL(string: "https://zoom.us/signin")!)
        #expect(decisions == [false])
        #expect((popup.customUserAgent ?? "").isEmpty)
        deferred.finish("Late Slides UA")
        await deferred.waitUntilReturned()
        #expect(decisions == [false])
        #expect((popup.customUserAgent ?? "").isEmpty)
    }

    @Test @MainActor func realWebKitNavigatorEnablesZoomSlidesSafariCompositionBranchOnlyOnScopedSites() async throws {
        let webView = makeWebView()
        let compatibility = try #require(await BrowserUserAgent.compatibilityUserAgent())
        let policy = BrowserUserAgent.NavigationPolicy(webView: webView, cachedCompatibilityUserAgent: nil)
        // The public Slides editor reads navigator.userAgent through its shared
        // detector. These are its two Safari patterns, not a Nous-only assertion.
        let slidesSafariDetector = #"/Version\/[0-9\._]+.*Safari/.test(navigator.userAgent) || /AppleWebKit\/.+Zoom/i.test(navigator.userAgent)"#
        let destinations = [
            ("https://slides.zoom.us/p/fixture", true),
            ("https://dg01slides.zoom.us/p/fixture", true),
            ("https://eu02slides.zoom.us/p/fixture", true),
            ("https://dg01present.zoom.us/p/fixture", true),
            ("https://zoom.us/signin", false),
            ("https://slides.zoom.com/", true),
            ("https://www.google.com/search?q=fixture", true),
            ("https://accounts.google.com/", false),
            ("https://present.zoom.us/", true),
            ("https://native.example.test/", false)
        ]
        for (index, destination) in destinations.enumerated() {
            let (address, expectedSafari) = destination
            let url = try #require(URL(string: address))
            let ready = await withCheckedContinuation { continuation in
                policy.prepare(for: url) { continuation.resume(returning: $0) }
            }
            #expect(ready)
            let title = "Slides identity \(index)"
            // No request is sent to Zoom or Google: load a local document with
            // the selected origin after the real navigation policy resolves.
            webView.loadHTMLString("<!doctype html><title>\(title)</title>", baseURL: url)
            for _ in 0..<150 {
                if !webView.isLoading, webView.title == title { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(webView.title == title)
            let userAgent = try #require(try await webView.evaluateJavaScript("navigator.userAgent") as? String)
            let recognized = try #require(try await webView.evaluateJavaScript(slidesSafariDetector) as? Bool)
            #expect(recognized == expectedSafari)
            // Exercise the observed Slides guard with this real Navigator's
            // identity. This is a deterministic site-policy regression, not
            // a synthetic-event substitute for native IME acceptance.
            let compositionGuard = """
            (() => {
                const browser = { safari: \(slidesSafariDetector) };
                let calls = 0;
                function keydown(isCompositing, elapsedSinceCompositionEnd) {
                    isCompositing ||
                        browser.safari && elapsedSinceCompositionEnd < 50 ||
                        ++calls;
                }
                keydown(true, 0);
                const whileComposing = calls;
                keydown(false, 1);
                const afterConfirmingEnter = calls;
                keydown(false, 100);
                return [whileComposing, afterConfirmingEnter, calls];
            })()
            """
            let calls = try #require(try await webView.evaluateJavaScript(compositionGuard) as? [Int])
            #expect(calls == (expectedSafari ? [0, 0, 1] : [0, 1, 2]))
            #expect(userAgent.contains("NousBrowser/"))
            if expectedSafari { #expect(userAgent == compatibility) }
            else { #expect(!userAgent.contains("Version/") && !userAgent.contains("Safari/")) }
        }
        webView.stopLoading()
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

    @Test @MainActor func cachedIdentityAppliesToSearchAndSupportedWorkspaceAppsSynchronouslyAndNativePagesClearIt() {
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
                        "https://docs.google.com/presentation/d/fixture",
                        "https://mail.google.com/", "https://mail.google.com/mail/u/0/"] {
            let previousCount = decisions.count
            policy.prepare(for: URL(string: address)!) { decisions.append($0) }
            #expect(decisions.count == previousCount + 1 && decisions.last == true)
            if #available(macOS 26.4, *) { #expect(webView.customUserAgent == "Fixture Search UA") }
            else { #expect((webView.customUserAgent ?? "").isEmpty) }
        }
        policy.prepare(for: URL(string: "https://accounts.google.com/")!) { decisions.append($0) }
        #expect(decisions == Array(repeating: true, count: 7))
        #expect((webView.customUserAgent ?? "").isEmpty)
        policy.applyKnownIdentity(for: URL(string: "https://google.com/webhp")!)
        #expect(webView.customUserAgent == "Fixture Search UA")
        for address in ["https://sheets.google.com/", "https://slides.google.com/",
                        "https://docs.google.com/document/d/fixture", "https://mail.google.com/mail/u/1/#inbox"] {
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

    @Test(arguments: ["https://docs.google.com/document/d/fixture", "https://docs.google.com/presentation/d/fixture",
                      "https://docs.google.com/spreadsheets/d/fixture", "https://mail.google.com/", "https://mail.google.com/mail/u/0/"])
    @MainActor func coldWorkspaceNavigationResolvesIdentityAndKeepsItAcrossAppSwitches(address: String) async {
        guard #available(macOS 26.4, *) else { return }
        let webView = makeWebView()
        let deferred = DeferredAgent()
        var resolverCalls = 0
        let policy = BrowserUserAgent.NavigationPolicy(webView: webView, cachedCompatibilityUserAgent: nil) {
            resolverCalls += 1
            return await deferred.resolve()
        }
        var decisions: [Bool] = []
        policy.prepare(for: URL(string: address)!) { decisions.append($0) }
        #expect(decisions.isEmpty)
        await deferred.waitUntilStarted()
        deferred.finish("Resolved Workspace UA")
        await deferred.waitUntilReturned()
        #expect(decisions == [true])
        #expect(webView.customUserAgent == "Resolved Workspace UA")

        let destinations = ["https://docs.google.com/document/d/fixture", "https://docs.google.com/presentation/d/fixture",
                            "https://docs.google.com/spreadsheets/d/fixture", "https://mail.google.com/mail/u/0/#inbox"]
        for destination in destinations {
            policy.prepare(for: URL(string: destination)!) { decisions.append($0) }
            #expect(webView.customUserAgent == "Resolved Workspace UA")
        }
        #expect(decisions == Array(repeating: true, count: destinations.count + 1))
        #expect(resolverCalls == 1)
        policy.prepare(for: URL(string: "https://accounts.google.com/")!) { decisions.append($0) }
        #expect(decisions == Array(repeating: true, count: destinations.count + 2))
        #expect((webView.customUserAgent ?? "").isEmpty)
    }

    @Test @MainActor func realWebKitProbeIsVisibleToWorkspaceAppsAndClearsForOtherSites() async throws {
        guard #available(macOS 26.4, *) else { return }
        let actualCompatibility = try #require(await BrowserUserAgent.compatibilityUserAgent())
        for address in ["https://docs.google.com/document/d/fixture", "https://docs.google.com/presentation/d/fixture",
                        "https://docs.google.com/spreadsheets/d/fixture", "https://mail.google.com/", "https://mail.google.com/mail/u/0/"] {
            let webView = makeWebView()
            var resolverCalls = 0
            // A fresh per-tab policy must resolve the real shared probe even
            // when there has not been a preceding Google Search navigation.
            let policy = BrowserUserAgent.NavigationPolicy(webView: webView, cachedCompatibilityUserAgent: nil) {
                resolverCalls += 1
                return await BrowserUserAgent.compatibilityUserAgent()
            }
            let workspaceURL = try #require(URL(string: address))
            let ready = await withCheckedContinuation { continuation in
                policy.prepare(for: workspaceURL) { continuation.resume(returning: $0) }
            }
            #expect(ready && resolverCalls == 1)
            #expect(webView.customUserAgent == actualCompatibility)
            // Use a local document with the selected origin so both reads
            // exercise a loaded Navigator without contacting any account.
            webView.loadHTMLString("<!doctype html><title>Workspace identity</title>", baseURL: workspaceURL)
            for _ in 0..<100 {
                if !webView.isLoading, webView.title == "Workspace identity" { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(webView.title == "Workspace identity")
            let workspaceAgent = try #require(try await webView.evaluateJavaScript("navigator.userAgent") as? String)
            #expect(workspaceAgent == actualCompatibility)
            #expect(workspaceAgent.contains("Version/26.4 Safari/"))
            #expect(workspaceAgent.contains("NousBrowser/"))

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

    @Test(arguments: ["https://docs.google.com/document/d/fixture", "https://docs.google.com/presentation/d/fixture",
                      "https://docs.google.com/spreadsheets/d/fixture", "https://mail.google.com/", "https://mail.google.com/mail/u/0/"])
    @MainActor func aPendingWorkspaceIdentityCannotRestoreCompatibilityAfterLeavingTheApp(address: String) async {
        guard #available(macOS 26.4, *) else { return }
        let webView = makeWebView()
        let deferred = DeferredAgent()
        let policy = BrowserUserAgent.NavigationPolicy(webView: webView, cachedCompatibilityUserAgent: nil) {
            await deferred.resolve()
        }
        var decisions: [Bool] = []
        policy.prepare(for: URL(string: address)!) { decisions.append($0) }
        await deferred.waitUntilStarted()
        policy.prepare(for: URL(string: "https://accounts.google.com/")!) { decisions.append($0) }
        #expect(decisions == [false, true])
        #expect((webView.customUserAgent ?? "").isEmpty)
        deferred.finish("Stale Workspace UA")
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
