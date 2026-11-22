import AppKit
import Testing
@testable import NousBrowser

@MainActor
@Suite("Screen capture permission and selection")
struct ScreenCapturePermissionTests {
    @Test func cancellingDenialRecoveryDoesNotOpenSettings() async throws {
        var presentations = 0
        let permission = ScreenCapturePermission(presentPrompt: {
            presentations += 1
            return false
        }, openSettings: { Issue.record("Cancel opened System Settings") })
        permission.offerSettingsAfterDenial()
        #expect(permission.isPresenting)
        try await waitForBrowserTest { !permission.isPresenting }
        #expect(presentations == 1)
    }

    @Test func repeatedDenialsHaveOneSheetWhichDismissesBeforeOpeningSettings() async throws {
        var answer: CheckedContinuation<Bool, Never>?
        var presentations = 0
        var settingsVisits = 0
        weak var presentedPermission: ScreenCapturePermission?
        let permission = ScreenCapturePermission(presentPrompt: {
            presentations += 1
            return await withCheckedContinuation { answer = $0 }
        }, openSettings: {
            #expect(presentedPermission?.isPresenting == false)
            settingsVisits += 1
        })
        presentedPermission = permission
        permission.offerSettingsAfterDenial()
        try await waitForBrowserTest { answer != nil }
        permission.offerSettingsAfterDenial()
        answer?.resume(returning: true)
        try await waitForBrowserTest { settingsVisits == 1 }
        #expect(presentations == 1)
        #expect(!permission.isPresenting)
    }

    @Test func selectionWithoutAFileIsDistinctFromAnInvalidOrInterruptedCapture() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(CaptureCoordinator.screenshotResult(at: output, status: 0, reason: .exit) == .noFile)
        #expect(CaptureCoordinator.screenshotResult(at: output, status: 1, reason: .exit) == .noFile)
        #expect(CaptureCoordinator.screenshotResult(at: output, status: 9, reason: .uncaughtSignal) == .failed)
        try Data().write(to: output)
        #expect(CaptureCoordinator.screenshotResult(at: output, status: 0, reason: .exit) == .failed)
        try Data([1, 2]).write(to: output)
        #expect(CaptureCoordinator.screenshotResult(at: output, status: 0, reason: .exit) == .failed)
        let data = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRt8AAAAASUVORK5CYII="))
        try data.write(to: output)
        #expect(CaptureCoordinator.screenshotResult(at: output, status: 1, reason: .exit) == .failed)
        #expect(CaptureCoordinator.screenshotResult(at: output, status: 0, reason: .exit) == .file(data))
    }
}
