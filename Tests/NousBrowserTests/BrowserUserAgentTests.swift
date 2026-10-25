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

    @Test @MainActor func normalAndInheritedPopupConfigurationsHaveOneConsistentSuffix() throws {
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
        #expect(tokens.filter { $0.hasPrefix("Version/") } == ["Version/26.0"])
        #expect(tokens.filter { $0.hasPrefix("Safari/") } == ["Safari/605.1.15"])
        #expect(tokens.filter { $0.hasPrefix("NousBrowser/") }.count == 1)
        #expect(!first.contains("Mozilla/") && !first.contains("Chrome/"))
    }
}
