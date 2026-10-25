import Foundation
import Testing
import WebKit
@testable import NousBrowser

@Suite("Fullscreen and popup blocking")
struct BrowserWebCompatibilityTests {
    @MainActor private func makeModel() -> (model: BrowserModel, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = BrowserModel(sessionURL: directory.appendingPathComponent("session.json"), restoreSession: false, loadSelectedTab: false)
        return (model, directory)
    }

    @MainActor private func load(_ html: String, in tab: BrowserTab) async throws {
        tab.webView.loadHTMLString(html, baseURL: URL(string: "https://popup.example.test/"))
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if tab.webView.url != nil, !tab.webView.isLoading { return }
        }
        Issue.record("The test page did not finish loading")
    }

    @Test @MainActor func pagesCanUseTheFullscreenAPIInEveryTab() async throws {
        let setup = makeModel()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let tab = try #require(setup.model.selectedTab)
        #expect(tab.webView.configuration.preferences.isElementFullscreenEnabled)
        try await load("<!doctype html><title>Fullscreen</title>", in: tab)
        let enabled = try await tab.webView.evaluateJavaScript("document.fullscreenEnabled")
        #expect(enabled as? Bool == true)
    }

    @Test @MainActor func scriptsWithoutUserActivationCannotOpenTabs() async throws {
        let setup = makeModel()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let tab = try #require(setup.model.selectedTab)
        try await load("<!doctype html><script>window.open('about:blank'); setTimeout(() => window.open('about:blank'), 50);</script>", in: tab)
        try await Task.sleep(for: .milliseconds(300))
        #expect(setup.model.tabs.count == 1)
        #expect(setup.model.selectedTabID == tab.id)
    }

    @Test @MainActor func userActivatedWindowOpenStillOpensATabWithTheSamePolicy() async throws {
        let setup = makeModel()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let tab = try #require(setup.model.selectedTab)
        try await load("<!doctype html><title>Opener</title>", in: tab)
        // evaluateJavaScript runs with a user gesture, like a click handler.
        _ = try await tab.webView.evaluateJavaScript("window.open('about:blank'); true")
        #expect(setup.model.tabs.count == 2)
        let popup = try #require(setup.model.selectedTab)
        #expect(popup.id != tab.id)
        #expect(!popup.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(popup.webView.configuration.preferences.isElementFullscreenEnabled)
    }
}
