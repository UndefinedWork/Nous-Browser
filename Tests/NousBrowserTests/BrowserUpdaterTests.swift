import Foundation
import Testing
import Sparkle
@testable import NousBrowser

@Suite("Update installation boundaries")
@MainActor struct BrowserUpdaterTests {
    @Test func compactUpdateControlIsNotATabDropTarget() {
        let size = CGSize(width: 60, height: 600)
        let point = CGPoint(x: 30, y: 452)
        #expect(SidebarTabDragGeometry.containsDropPoint(point, viewport: size, isCompact: true))
        #expect(!SidebarTabDragGeometry.containsDropPoint(point, viewport: size, isCompact: true, additionalBottomInset: 40))
    }
    @Test func cannotInstallWithoutUserRequest() {
        let updater = BrowserUpdater()
        var choice: SPUUserUpdateChoice?
        updater.showReady(toInstallAndRelaunch: { choice = $0 })
        #expect(choice == .dismiss)
        #expect(updater.phase == .idle)
    }
    @Test func noUpdateResultSurvivesSparkleDismissal() {
        let updater = BrowserUpdater()
        #expect(updater.checkFeedback == nil)
        let result = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Up to date",
            NSLocalizedRecoverySuggestionErrorKey: "The installed build is newer than the published version."
        ])
        var acknowledged = false
        updater.showUpdateNotFoundWithError(result) { acknowledged = true }
        updater.dismissUpdateInstallation()
        #expect(acknowledged)
        #expect(updater.phase == .idle)
        #expect(updater.lastChecked != nil)
        #expect(updater.checkFeedback?.title == L10n.string("No update available"))
        #expect(updater.checkFeedback?.detail == result.localizedRecoverySuggestion)
    }
    @Test func checkFailureReplacesAnEarlierSuccess() {
        let updater = BrowserUpdater()
        updater.showUpdateNotFoundWithError(NSError(domain: "test", code: 1)) {}
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        updater.showUpdaterError(offline) {}
        updater.dismissUpdateInstallation()
        #expect(updater.checkFeedback?.title == L10n.string("Unable to update"))
        #expect(updater.checkFeedback?.detail.contains(offline.localizedDescription) == true)
        #expect(updater.phase == .idle)
    }
    @Test func executableAndTestProcessesDoNotStartUpdater() {
        #expect(!BrowserUpdater.permitsUpdates(bundle: .main))
    }
    @Test func distributionAndReceiptGate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.nous.update." + UUID().uuidString, "CFBundlePackageType": "APPL", "NousDistributionChannel": "github"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appendingPathComponent("Contents/Info.plist"))
        let bundle = try #require(Bundle(url: root))
        #expect(BrowserUpdater.permitsUpdates(bundle: bundle))
        let receipt = try #require(bundle.appStoreReceiptURL)
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("receipt".utf8).write(to: receipt)
        #expect(!BrowserUpdater.permitsUpdates(bundle: bundle))
    }
    @Test func extractionCannotInheritCancellationAndDismissResetsState() {
        let updater = BrowserUpdater()
        updater.showDownloadDidReceiveExpectedContentLength(100)
        updater.showDownloadDidReceiveData(ofLength: 150)
        #expect(updater.progress == 1)
        updater.showDownloadDidStartExtractingUpdate()
        #expect(updater.phase == .installing)
        #expect(!updater.canCancel)
        updater.dismissUpdateInstallation()
        #expect(updater.phase == .idle)
        #expect(!updater.showsButton)
        #expect(updater.progress == nil)
    }
}
