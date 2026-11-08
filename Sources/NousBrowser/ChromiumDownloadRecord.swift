import AppKit
import Combine

/// Engine-independent transfer state; all bytes still come from Chromium's
/// original native download. The destination helper installs the file atomically after completion.
@MainActor
final class ChromiumDownloadRecord: ObservableObject, Identifiable {
    enum State: Equatable {
        case choosingDestination, transferring, completed, canceled, failed(String)
        var isActive: Bool {
            self == .choosingDestination || self == .transferring
        }
    }

    let id: String
    let filename: String
    weak var sourceWindow: NSWindow?
    @Published private(set) var state: State = .choosingDestination
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    private(set) var finalURL: URL?
    private var destination: BrowserDownloadDestination?
    private var chooseNative: ((URL) -> Void)?
    private var cancelNative: (() -> Void)?

    init(id: String, filename: String, sourceWindow: NSWindow?,
         choose: @escaping (URL) -> Void, cancel: @escaping () -> Void) {
        self.id = id
        self.filename = filename
        self.sourceWindow = sourceWindow
        chooseNative = choose
        cancelNative = cancel
    }

    func chooseDestination(_ url: URL?) {
        guard state == .choosingDestination else { return }
        guard let url else { cancel(); return }
        do {
            let destination = try BrowserDownloadDestination(url: url)
            self.destination = destination
            finalURL = destination.url
            state = .transferring
            let choose = chooseNative
            chooseNative = nil
            choose?(destination.stagingURL)
        } catch { fail(error.localizedDescription) }
    }

    func receive(state nativeState: Int, received: Int64 = 0, total: Int64 = 0,
                 path: String? = nil, reason: Int = 0, sourceClosed: Bool = false,
                 explicitCancellation: Bool = false) {
        guard state.isActive else { return } // Ignore stale/repeated completion.
        let received = max(0, received), total = max(0, total)
        if receivedBytes != received { receivedBytes = received }
        if totalBytes != total { totalBytes = total }
        switch nativeState {
        case 0: break
        case 1:
            guard state == .transferring, let destination, let path,
                  URL(fileURLWithPath: path).standardizedFileURL == destination.stagingURL else {
                fail(L10n.string("The download did not finish at the selected destination."))
                return
            }
            do {
                try destination.commit()
                self.destination = nil
                state = .completed
                releaseNativeCallbacks()
            } catch { fail(error.localizedDescription) }
        case 2:
            // Chromium may cancel its item after an interrupted response or an
            // unavailable target. Only a host/user cancellation means Canceled.
            if explicitCancellation { cancel() }
            else { fail(L10n.string("The download was interrupted. Please try again.")) }
        case 3:
            fail(sourceClosed
                ? L10n.string("The download stopped because its source tab closed.")
                : L10n.string("The download was interrupted. Please try again."))
        default:
            fail(L10n.string("The download stopped before it finished."))
        }
    }

    func cancel() {
        guard state.isActive else { return }
        state = .canceled
        let cancel = cancelNative
        releaseNativeCallbacks()
        cancel?() // Update state first; native cancellation may reenter.
        destination?.cancel()
        destination = nil
    }

    private func fail(_ message: String) {
        guard state.isActive else { return }
        state = .failed(message)
        let cancel = cancelNative
        releaseNativeCallbacks()
        cancel?()
        destination?.cancel()
        destination = nil
    }

    private func releaseNativeCallbacks() {
        chooseNative = nil
        cancelNative = nil
    }
}
