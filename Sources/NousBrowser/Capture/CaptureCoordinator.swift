import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Screenshot and recording entry points. Capture reuses Pico's flows (the
/// system selection UI and Pico's ScreenCaptureKit recorder); the result
/// opens as an editor tab and is saved to the Library.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()
    private let screenAccess = ScreenCapturePermission()
    private let recorder = ScreenRecordingController()
    private var screenshotProcess: Process?
    /// Where the editor tab opens.
    var openPage: (NativePage, BrowserTab?) -> Void = { _, _ in }
    var report: (String) -> Void = { _ in }

    var isRecording: Bool { recorder.isRecording }

    private init() {
        recorder.failed = { [weak self] message in self?.report(message) }
        recorder.screenAccessDenied = { [weak self] in self?.screenAccess.offerSettingsAfterDenial() }
        recorder.finished = { [weak self] result in self?.recordingFinished(result) }
    }

    /// Crosshair selection; Space switches to window capture; Escape cancels.
    func takeScreenshot(from source: BrowserTab?) {
        guard screenshotProcess == nil, !screenAccess.isPresenting else { return }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("NousScreenshot-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // Let the system selector show its own capture errors. Escape and
        // Control-click (clipboard only) both legitimately leave no file.
        process.arguments = ["-i", "-J", "selection", "-d", "-t", "png", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self, weak source] ended in
            let status = ended.terminationStatus
            let reason = ended.terminationReason
            Task { @MainActor [weak self, weak source] in
                guard let self else { return }
                self.screenshotProcess = nil
                defer { try? FileManager.default.removeItem(at: output) }
                switch Self.screenshotResult(at: output, status: status, reason: reason) {
                case .file(let data):
                    self.saveScreenshot(data, from: source)
                case .noFile:
                    break
                case .failed:
                    self.report(L10n.string("Could not complete the screenshot."))
                }
            }
        }
        screenshotProcess = process
        do { try process.run() }
        catch {
            screenshotProcess = nil
            report(L10n.string("Could not start screenshot selection."))
        }
    }

    enum ScreenshotResult: Equatable { case file(Data), noFile, failed }

    static func screenshotResult(at url: URL, status: Int32, reason: Process.TerminationReason) -> ScreenshotResult {
        guard reason == .exit else { return .failed }
        guard FileManager.default.fileExists(atPath: url.path) else { return .noFile }
        guard status == 0, let data = try? Data(contentsOf: url),
              let image = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(image) as String? == UTType.png.identifier,
              CGImageSourceGetCount(image) > 0,
              CGImageSourceGetStatus(image) == .statusComplete else { return .failed }
        return .file(data)
    }

    /// The visible part of the current webpage, without the browser around it.
    func capturePage(_ tab: BrowserTab?) {
        guard let tab, tab.hasWebContent else { takeScreenshot(from: tab); return }
        let webView = tab.webView
        Task { [weak tab] in
            do { saveScreenshot(try await webView.captureImage(), from: tab) }
            catch { report(L10n.string("Could not capture this page.")) }
        }
    }

    private func saveScreenshot(_ data: Data, from source: BrowserTab?) {
        do {
            let capture = try LibraryStore.shared.saveScreenshot(data)
            NSApp.activate(ignoringOtherApps: true)
            openPage(capture.page, source)
        } catch {
            report(error.localizedDescription)
        }
    }

    func toggleRecording() {
        if recorder.isRecording { recorder.stop() }
        else if !recorder.isBusy, !screenAccess.isPresenting { recorder.start() }
    }

    private func recordingFinished(_ result: ScreenRecordingController.Result) {
        do {
            let capture = try LibraryStore.shared.importRecording(result.url, startedAt: result.startedAt)
            var document = RecordingDocument()
            document.cursor = result.cursor
            LibraryStore.shared.saveEdit(document, for: capture)
            NSApp.activate(ignoringOtherApps: true)
            openPage(capture.page, nil)
        } catch {
            report(L10n.string("Could not save the recording.") + " " + error.localizedDescription)
        }
    }

    func finishBeforeQuit() async { await recorder.finishBeforeQuit() }
}
