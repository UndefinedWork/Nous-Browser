import Foundation
import AVFoundation
import ScreenCaptureKit

/// Separates capture lifetime from output lifetime: the system can end the movie
/// without ending the SCStream which owns its menu-bar controls.
@MainActor protocol RecordingCapture: AnyObject {
    func start() async throws
    func stop() async throws
    func detach() throws
}

@available(macOS 15, *)
@MainActor private final class SystemRecordingCapture: RecordingCapture {
    private let stream: SCStream
    private let output: SCRecordingOutput
    init(filter: SCContentFilter, configuration: SCStreamConfiguration, url: URL, delegate: ScreenRecorder) throws {
        let settings = SCRecordingOutputConfiguration()
        settings.outputURL = url
        settings.outputFileType = .mp4
        settings.videoCodecType = .h264
        output = SCRecordingOutput(configuration: settings, delegate: delegate)
        stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        try stream.addRecordingOutput(output)
    }
    func start() async throws { try await stream.startCapture() }
    func stop() async throws { try await stream.stopCapture() }
    func detach() throws { try stream.removeRecordingOutput(output) }
}

/// All stop paths converge here, including system controls and callbacks arriving
/// while startCapture is still returning. A movie is saved only after finalization.
@available(macOS 15, *)
@MainActor final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    let url: URL
    var interrupted: () -> Void = {}
    private(set) var hasRequestedStop = false
    private var capture: RecordingCapture?
    private var starting: Task<Void, Error>?
    private var stopping: Task<Error?, Never>?
    private var streamEnded = false
    private var captureError: Error?
    private var outputEnded = false
    private var outputError: Error?
    private var waiter: CheckedContinuation<Void, Never>?
    private var deadline: Task<Void, Never>?
    private let finalizationTimeout: UInt64

    init(url: URL, finalizationTimeout: UInt64 = 6_000_000_000) {
        self.url = url
        self.finalizationTimeout = finalizationTimeout
    }

    func start(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        try await start(capture: SystemRecordingCapture(filter: filter, configuration: configuration, url: url, delegate: self))
    }

    func start(capture: RecordingCapture) async throws {
        precondition(self.capture == nil && starting == nil, "A recorder may only start once")
        self.capture = capture
        let task = Task { try await capture.start() }
        starting = task
        do { try await task.value }
        catch {
            captureError = error
            // No successful start means a finalization callback is not guaranteed.
            finishOutput(error)
            _ = await stop()
            throw error
        }
    }

    func stop() async -> Error? {
        requestStop()
        return await stopping?.value
    }

    private func requestStop() {
        guard !hasRequestedStop else { return }
        hasRequestedStop = true
        stopping = Task { await finishCapture() }
        interrupted()
    }

    private func finishCapture() async -> Error? {
        // Never release a stream or race stopCapture against a pending start.
        if let starting {
            do { try await starting.value }
            catch { captureError = captureError ?? error; finishOutput(error) }
        }
        if let capture, !streamEnded {
            do { try await capture.stop() }
            catch {
                let nsError = error as NSError
                // A simultaneous system stop can win before its delegate is delivered.
                if nsError.domain != SCStreamErrorDomain || nsError.code != SCStreamError.attemptToStopStreamState.rawValue {
                    captureError = captureError ?? error
                }
            }
        }
        if !outputEnded {
            await withCheckedContinuation { continuation in
                waiter = continuation
                deadline = Task { [weak self] in
                    guard let self else { return }
                    do { try await Task.sleep(nanoseconds: finalizationTimeout) }
                    catch { return }
                    finishOutput(NSError(domain: "Nous.ScreenRecording", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the recording file to finish"]))
                }
            }
        }
        // Detach only after the output has completed, keeping the delegate alive
        // until the movie writer has closed. Always release both stream and output.
        if let capture {
            do { try capture.detach() }
            catch {
                // The system may already have removed a completed output.
                // Capture/finalization errors above remain authoritative.
            }
        }
        capture = nil
        starting = nil
        deadline?.cancel(); deadline = nil
        interrupted = {}
        return outputError ?? captureError
    }

    private func finishOutput(_ error: Error?) {
        guard !outputEnded else { return }
        outputEnded = true
        outputError = error
        deadline?.cancel(); deadline = nil
        waiter?.resume(); waiter = nil
    }

    /// Also used when the system stops only the recording output.
    func outputFinished(error: Error? = nil) {
        finishOutput(error)
        requestStop()
    }

    func captureStopped(error: Error) {
        streamEnded = true
        let nsError = error as NSError
        if nsError.domain != SCStreamErrorDomain || ![SCStreamError.userStopped.rawValue, SCStreamError.systemStoppedStream.rawValue].contains(nsError.code) {
            captureError = captureError ?? error
        }
        requestStop()
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.outputFinished() }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in self.outputFinished(error: error) }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.captureStopped(error: error) }
    }
}
