import AppKit
import Observation
import Sparkle
import SwiftUI

/// One updater per application, shared by every window. Sparkle owns archive
/// authentication, installation and relaunch; webpages never control this path.
@MainActor
@Observable
final class BrowserUpdater: NSObject, SPUUserDriver {
    static let shared = BrowserUpdater()
    enum Phase: Equatable { case idle, checking, available, downloading, installing }
    private(set) var phase: Phase = .idle
    private(set) var version = ""
    private(set) var progress: Double?
    private(set) var isEnabled = false
    var showsButton: Bool { phase == .available || phase == .downloading || phase == .installing }
    var isBusy: Bool { phase == .checking || phase == .downloading || phase == .installing }
    @ObservationIgnored private var engine: SPUUpdater?
    @ObservationIgnored private var installReply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var cancellation: (() -> Void)?
    @ObservationIgnored private var progressWindow: NSWindow?
    @ObservationIgnored private var expectedBytes: UInt64 = 0
    @ObservationIgnored private var receivedBytes: UInt64 = 0
    @ObservationIgnored private var userRequestedCheck = false
    @ObservationIgnored private var installWasRequested = false

    static func permitsUpdates(bundle: Bundle) -> Bool {
        guard bundle.bundleURL.pathExtension == "app",
              bundle.object(forInfoDictionaryKey: "NousDistributionChannel") as? String == "github" else { return false }
        if let receipt = bundle.appStoreReceiptURL, FileManager.default.fileExists(atPath: receipt.path) { return false }
        return true
    }

    func start() {
        guard engine == nil, Self.permitsUpdates(bundle: .main) else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
        engine = updater
        do {
            try updater.start()
            isEnabled = true
        } catch {
            engine = nil
            NSLog("Nous updater could not start: %@", error.localizedDescription)
        }
    }

    func checkForUpdates() {
        guard isEnabled, let engine else { return }
        if phase == .available { installUpdate(); return }
        if isBusy { showProgress(); return }
        userRequestedCheck = true
        engine.checkForUpdates()
    }

    func installUpdate() {
        guard phase == .available, let reply = installReply else {
            if isBusy { showProgress() }
            return
        }
        installReply = nil
        installWasRequested = true
        phase = .downloading
        progress = nil
        showProgress()
        reply(.install)
    }

    func cancel() {
        guard let action = cancellation else { return }
        cancellation = nil
        action()
    }
    var canCancel: Bool { cancellation != nil }
    var status: String {
        switch phase {
        case .idle: L10n.string("Check for Updates…")
        case .checking: L10n.string("Checking for updates…")
        case .available: L10n.string("Update available")
        case .downloading: L10n.string("Downloading update…")
        case .installing: L10n.string("Installing and restarting…")
        }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // The GitHub distribution explicitly opts into checks in Info.plist.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        phase = .checking; progress = nil; self.cancellation = cancellation
        showProgress()
    }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil
        guard !appcastItem.isInformationOnlyUpdate else {
            reply(.dismiss)
            if userRequestedCheck { showMessage(L10n.string("Update unavailable"), detail: L10n.string("This update cannot be installed automatically.")) }
            return
        }
        version = appcastItem.displayVersionString
        phase = .available
        installReply = reply
        progressWindow?.orderOut(nil)
        // A menu check reveals the update without implicitly authorizing restart.
        if userRequestedCheck {
            let alert = NSAlert()
            alert.messageText = L10n.string("Update available") + " — " + version
            alert.informativeText = L10n.string("Download the update, then restart Nous Browser. Save any work in webpages first.")
            alert.addButton(withTitle: L10n.string("Update and Restart"))
            alert.addButton(withTitle: L10n.string("Later"))
            if alert.runModal() == .alertFirstButtonReturn { installUpdate() }
        }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        progressWindow?.orderOut(nil)
        if userRequestedCheck { showMessage(L10n.string("No update available"), detail: error.localizedDescription) }
        acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        progressWindow?.orderOut(nil)
        if userRequestedCheck || installWasRequested { showMessage(L10n.string("Unable to update"), detail: error.localizedDescription) }
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        phase = .downloading; self.cancellation = cancellation
        expectedBytes = 0; receivedBytes = 0; progress = nil
        showProgress()
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes = receivedBytes.addingReportingOverflow(length).partialValue
        progress = expectedBytes > 0 ? min(1, Double(receivedBytes) / Double(expectedBytes)) : nil
    }
    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil; phase = .installing; progress = nil
    }
    func showExtractionReceivedProgress(_ progress: Double) { self.progress = progress }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Only a direct button/menu action authorizes download and restart.
        guard installWasRequested else { reply(.dismiss); return }
        phase = .installing; cancellation = nil; progress = nil
        reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing; progress = nil
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {
        phase = .idle; progress = nil; cancellation = nil; installReply = nil
        userRequestedCheck = false; installWasRequested = false
        progressWindow?.close(); progressWindow = nil
    }
    func showUpdateInFocus() {
        if phase == .available { installUpdate() } else { showProgress() }
    }

    private func showMessage(_ title: String, detail: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: L10n.string("OK")); alert.runModal()
    }
    private func showProgress() {
        if progressWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Nous Browser"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: BrowserUpdateProgress(updater: self))
            window.center(); progressWindow = window
        }
        progressWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct BrowserUpdateProgress: View {
    @Bindable var updater: BrowserUpdater
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(updater.status).font(.headline)
            if let progress = updater.progress { ProgressView(value: progress) }
            else { ProgressView().controlSize(.small) }
            if updater.canCancel { Button(L10n.string("Cancel"), action: updater.cancel) }
        }.padding(24).frame(width: 360, height: 140, alignment: .leading)
    }
}
