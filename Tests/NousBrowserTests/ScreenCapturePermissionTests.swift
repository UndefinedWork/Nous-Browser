import AppKit
import Testing
@testable import NousBrowser

@MainActor
@Suite("Screen capture permission and selection")
struct ScreenCapturePermissionTests {
    @Test func existingGrantOpensSelectorWithoutAnotherRequest() {
        let permission = ScreenCapturePermission(preflight: { true }, request: {
            Issue.record("An authorized command requested access again")
            return false
        }, offerRetry: { _ in Issue.record("Unexpected recovery prompt"); return false })
        var selections = 0
        permission.perform { selections += 1 }
        #expect(selections == 1)
    }

    @Test func denyingAndCancellingDoesNotCaptureOrQueueAnotherShortcut() async throws {
        var prompts = 0
        var retry: CheckedContinuation<Bool, Never>?
        let permission = ScreenCapturePermission(preflight: { false }, request: { false }) { _ in
            prompts += 1
            return await withCheckedContinuation { retry = $0 }
        }
        var selections = 0
        permission.perform { selections += 1 }
        try await waitForBrowserTest { retry != nil }
        permission.perform { selections += 1 }
        retry?.resume(returning: false)
        await Task.yield()
        #expect(selections == 0)
        #expect(prompts == 1)
    }

    @Test func retryRechecksAccessAndOpensOnlyTheOriginalSelector() async throws {
        var hasAccess = false
        var retries: [Bool] = []
        let permission = ScreenCapturePermission(preflight: { hasAccess }, request: { false }) { retried in
            retries.append(retried)
            if retried { hasAccess = true }
            return true
        }
        var selections = 0
        permission.perform { selections += 1 }
        try await waitForBrowserTest { selections > 0 }
        #expect(retries == [false, true])
        #expect(selections == 1)
    }

    @Test func aStreamDenialRequiresAPositiveRetryEvenIfPreflightPasses() async throws {
        var offered = false
        let permission = ScreenCapturePermission(preflight: { true }, request: {
            Issue.record("Redundant system request after the stream reported denial")
            return false
        }) { _ in offered = true; return false }
        var opened = false
        permission.perform(afterDenial: true) { opened = true }
        try await waitForBrowserTest { offered }
        #expect(!opened)
    }

    @Test func selectionWithoutAFileIsDistinctFromAnInvalidOrInterruptedCapture() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
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
