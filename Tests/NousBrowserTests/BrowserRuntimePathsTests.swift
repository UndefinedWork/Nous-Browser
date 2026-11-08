import Foundation
import NousAutomation
import Testing
@testable import NousBrowser

@Suite("Browser distribution data routing")
struct BrowserRuntimePathsTests {
    @Test func onlyExplicitMatchingIdentitiesMayStart() {
        #expect(BrowserRuntimePaths.Distribution.resolve(bundleIdentifier: "com.cellier.nous-browser",
            channel: "github") == .production)
        #expect(BrowserRuntimePaths.Distribution.resolve(bundleIdentifier: "com.cellier.nous-browser.chromium-preview",
            channel: "chromium-preview") == .preview)
        for (identifier, channel) in [
            ("com.cellier.nous-browser", "chromium-preview"),
            ("com.cellier.nous-browser.chromium-preview", "github"),
            ("com.cellier.nous-browser", ""),
            ("unknown", "github"), ("unknown", "chromium-preview")
        ] {
            #expect(BrowserRuntimePaths.Distribution.resolve(bundleIdentifier: identifier, channel: channel) == nil)
        }
        #expect(BrowserRuntimePaths.Distribution.resolve(bundleIdentifier: nil, channel: nil) == nil)
    }

    @Test func productionKeepsExistingSessionsAndDefaultMCPAddress() {
        let support = URL(fileURLWithPath: "/synthetic/Library/Application Support", isDirectory: true)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = BrowserRuntimePaths(distribution: .production, applicationSupport: support, home: home)
        #expect(paths.directory.path == "/synthetic/Library/Application Support/Nous Browser")
        #expect(paths.sessionURL.path == "/synthetic/Library/Application Support/Nous Browser/session.json")
        #expect(paths.chromiumProfileDirectory.path == "/synthetic/Library/Application Support/Nous Browser/Chromium")
        #expect(paths.automationSocketPath == AutomationEndpoint.defaultSocketPath)
    }

    @Test func previewRemainsSeparateForAllWritableEndpoints() {
        let root = URL(fileURLWithPath: "/synthetic", isDirectory: true)
        let production = BrowserRuntimePaths(distribution: .production, applicationSupport: root, home: root)
        let preview = BrowserRuntimePaths(distribution: .preview, applicationSupport: root, home: root)
        #expect(preview.directory.path == "/synthetic/Nous Browser Chromium Preview")
        #expect(preview.sessionURL != production.sessionURL)
        #expect(preview.chromiumProfileDirectory != production.chromiumProfileDirectory)
        #expect(preview.automationSocketPath == "/synthetic/.local/share/NousBrowser/previews/chromium/bridge.sock")
        #expect(preview.automationSocketPath != production.automationSocketPath)
    }

    @Test func qaSessionOverrideAppliesOnlyToPreviewAndRequiresAbsolutePath() {
        let root = URL(fileURLWithPath: "/synthetic", isDirectory: true)
        let production = BrowserRuntimePaths(distribution: .production, applicationSupport: root, home: root)
        let preview = BrowserRuntimePaths(distribution: .preview, applicationSupport: root, home: root)
        #expect(production.sessionURL(qaOverride: "/tmp/synthetic-qa.json") == production.sessionURL)
        #expect(preview.sessionURL(qaOverride: "/tmp/synthetic-qa.json").path == "/tmp/synthetic-qa.json")
        for invalid in [nil, "", "relative-session.json"] as [String?] {
            #expect(preview.sessionURL(qaOverride: invalid) == preview.sessionURL)
        }
    }
}
