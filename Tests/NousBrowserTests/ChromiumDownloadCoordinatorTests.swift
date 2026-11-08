import AppKit
import NousCore
import Testing
@testable import NousBrowser

/// Uses the real coordinator with nonpresenting AppKit panels and synthetic
/// native jobs. No CEF process, browser profile, file dialog, or page is opened.
@Suite("Chromium queued downloads and quit decisions", .serialized)
@MainActor
struct ChromiumDownloadCoordinatorTests {
    private func setup() -> (ChromiumDownloadCoordinator, DownloadTestUI) {
        _ = NSApplication.shared
        let ui = DownloadTestUI()
        let coordinator = ChromiumDownloadCoordinator(makeSavePanel: { ui.panel() },
            makeAlert: { ui.alert() }, showWindow: { _ in })
        coordinator.start()
        return (coordinator, ui)
    }

    private func job(_ id: String, window: NSWindow? = nil) -> DownloadTestJob {
        let job = DownloadTestJob(id: id, window: window)
        NBChromiumDownloadCenter.shared().newDownloadHandler?(job)
        return job
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func sourceWindowClosesOnlyItsUnconfirmedChoices() async throws {
        let (coordinator, ui) = setup()
        defer { coordinator.shutdown() }
        let source = window(), other = window()
        defer { source.close(); other.close() }
        let first = job("first", window: source)
        let second = job("second", window: source)
        let retained = job("other", window: other)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: source)
        try await waitForBrowserTest { ui.panels.count == 2 }
        #expect(first.cancels == 1 && second.cancels == 1 && retained.cancels == 0)
        #expect(ui.panels.map(\.nameFieldStringValue) == ["first.bin", "other.bin"])
        #expect(coordinator.records.filter { $0.state.isActive }.count == 1)
        #expect(coordinator.hasActiveDownloads)
    }

    @Test func nativeSourceCloseBatchCannotShowAnotherStaleSavePanel() async throws {
        let (coordinator, ui) = setup()
        defer { coordinator.shutdown() }
        let first = job("first"), second = job("second")
        _ = job("other")
        // Native source-close callbacks arrive oldest-ID first, synchronously.
        first.cancel()
        second.cancel()
        try await waitForBrowserTest { ui.panels.count == 2 }
        #expect(ui.panels.map(\.nameFieldStringValue) == ["first.bin", "other.bin"])
        #expect(coordinator.records.filter { $0.state.isActive }.count == 1)
    }

    @Test func quitWaitsForSaveSheetToDetachAndCanceledQuitRestoresTheSameChoice() async throws {
        let (coordinator, ui) = setup()
        defer { coordinator.shutdown() }
        let first = job("first"), second = job("second")
        let initialPanel = try #require(ui.panels.first)
        initialPanel.nameFieldStringValue = "My edited filename.bin"
        initialPanel.directoryURL = FileManager.default.temporaryDirectory
        let editedDirectory = initialPanel.directoryURL
        initialPanel.deferCancellation = true
        var quitAccepted: Bool?
        coordinator.confirmTermination { quitAccepted = $0 }
        let alert = try #require(ui.alerts.last)
        alert.respond(.alertSecondButtonReturn)
        #expect(quitAccepted == nil) // beforeunload cannot start with Save attached.
        #expect(first.cancels == 0 && second.cancels == 0)
        initialPanel.finishDeferredCancellation()
        #expect(quitAccepted == true)
        #expect(coordinator.records.allSatisfy { $0.state == .choosingDestination })
        #expect(ui.panels.count == 1)
        coordinator.resumeAfterCancelledTermination()
        try await waitForBrowserTest { ui.panels.count == 2 }
        #expect(ui.panels.last?.nameFieldStringValue == "My edited filename.bin")
        #expect(ui.panels.last?.directoryURL == editedDirectory)
        #expect(first.cancels == 0 && second.cancels == 0)
        // The old sheet cannot cancel the newly restored choice.
        initialPanel.repeatLastResponse(.cancel)
        #expect(coordinator.records.allSatisfy { $0.state == .choosingDestination })
        #expect(coordinator.hasActiveDownloads)
    }

    @Test func repeatedQuitRestoresLatestEditsWithoutSharingDraftsBetweenDownloads() async throws {
        let (coordinator, ui) = setup()
        defer { coordinator.shutdown() }
        let first = job("first"), second = job("second")
        let defaultDirectory = ui.panels[0].directoryURL
        for (index, filename) in ["First draft.bin", "Revised draft.bin"].enumerated() {
            let panel = try #require(ui.panels.last)
            panel.nameFieldStringValue = filename
            panel.directoryURL = index == 0 ? FileManager.default.temporaryDirectory
                : URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            let directory = panel.directoryURL
            var accepted = false
            coordinator.confirmTermination { accepted = $0 }
            ui.alerts.last?.respond(.alertSecondButtonReturn)
            #expect(accepted)
            let panelCount = ui.panels.count
            coordinator.resumeAfterCancelledTermination()
            try await waitForBrowserTest { ui.panels.count == panelCount + 1 }
            #expect(ui.panels.last?.nameFieldStringValue == filename)
            #expect(ui.panels.last?.directoryURL == directory)
        }
        ui.panels.last?.cancel(nil)
        try await waitForBrowserTest { ui.panels.count == 4 }
        #expect(first.cancels == 1 && second.cancels == 0)
        #expect(ui.panels.last?.nameFieldStringValue == "second.bin")
        #expect(ui.panels.last?.directoryURL == defaultDirectory)
        ui.panels.last?.nameFieldStringValue = "Second independent draft.bin"
        ui.panels.last?.directoryURL = FileManager.default.temporaryDirectory
        let secondDirectory = ui.panels.last?.directoryURL
        coordinator.confirmTermination { _ in }
        ui.alerts.last?.respond(.alertSecondButtonReturn)
        coordinator.resumeAfterCancelledTermination()
        try await waitForBrowserTest { ui.panels.count == 5 }
        #expect(ui.panels.last?.nameFieldStringValue == "Second independent draft.bin")
        #expect(ui.panels.last?.directoryURL == secondDirectory)
    }

    @Test func canceledSuspendedJobDropsItsDraftAndRestoresNextUnrelatedChoice() async throws {
        let (coordinator, ui) = setup()
        defer { coordinator.shutdown() }
        let first = job("first"), second = job("second")
        let defaultDirectory = ui.panels[0].directoryURL
        ui.panels[0].nameFieldStringValue = "Canceled draft.bin"
        ui.panels[0].directoryURL = FileManager.default.temporaryDirectory
        coordinator.confirmTermination { _ in }
        ui.alerts.last?.respond(.alertSecondButtonReturn)
        first.cancel() // Source closes while beforeunload is awaiting a decision.
        #expect(ui.panels.count == 1)
        coordinator.clearFinished()
        coordinator.resumeAfterCancelledTermination()
        try await waitForBrowserTest { ui.panels.count == 2 }
        #expect(ui.panels.last?.nameFieldStringValue == "second.bin")
        #expect(ui.panels.last?.directoryURL == defaultDirectory)
        #expect(coordinator.records.count == 1 && second.cancels == 0)
    }

    @Test func keepDownloadingDoesNotSuspendOrCancelAndShutdownDoesNotAdvanceQueue() {
        let (coordinator, ui) = setup()
        let first = job("first"), second = job("second")
        var answer: Bool?
        coordinator.confirmTermination { answer = $0 }
        ui.alerts.last?.respond(.alertFirstButtonReturn)
        #expect(answer == false && first.cancels == 0 && second.cancels == 0)
        #expect(ui.panels.count == 1 && ui.panels[0].cancellations == 0)
        coordinator.shutdown()
        coordinator.shutdown()
        #expect(first.cancels == 1 && second.cancels == 1)
        #expect(!coordinator.hasActiveDownloads)
        #expect(ui.panels.count == 1)
    }

    @Test func downloadsArrivingDuringAnInitiallyEmptyQuitWaitForItsOutcome() async throws {
        let (coordinator, ui) = setup()
        defer { coordinator.shutdown() }
        var accepted = false
        coordinator.confirmTermination { accepted = $0 }
        #expect(accepted && ui.alerts.isEmpty)
        let late = job("late")
        #expect(ui.panels.isEmpty && late.cancels == 0)
        coordinator.resumeAfterCancelledTermination()
        try await waitForBrowserTest { ui.panels.count == 1 }
        #expect(ui.panels.first?.nameFieldStringValue == "late.bin")
        #expect(late.cancels == 0 && coordinator.hasActiveDownloads)
    }
}

private final class DownloadTestJob: NBChromiumDownloadJob {
    private let testID: String
    private weak var testWindow: NSWindow?
    private var testSnapshot: [String: Any] = ["state": 0]
    private(set) var cancels = 0
    override var identifier: String { testID }
    override var suggestedFilename: String { testID + ".bin" }
    override var mimeType: String { "application/octet-stream" }
    override var sourceWindow: NSWindow? { testWindow }
    override var snapshot: [String: Any] { testSnapshot }
    init(id: String, window: NSWindow?) {
        testID = id
        testWindow = window
        super.init()
    }
    override func cancel() {
        guard cancels == 0 else { return }
        cancels += 1
        testSnapshot = ["state": 2, "explicitCancellation": true]
        updateHandler?(self)
    }
    override func chooseDestination(_ url: URL?) {}
}

@MainActor
private final class DownloadTestUI {
    var panels: [DownloadTestPanel] = []
    var alerts: [DownloadTestAlert] = []
    func panel() -> NSSavePanel {
        let panel = DownloadTestPanel()
        panels.append(panel)
        return panel
    }
    func alert() -> NSAlert {
        let alert = DownloadTestAlert()
        alerts.append(alert)
        return alert
    }
}

@MainActor
private final class DownloadTestPanel: NSSavePanel {
    var deferCancellation = false
    var cancellations = 0
    private var completion: (@MainActor @Sendable (NSApplication.ModalResponse) -> Void)?
    private var lastCompletion: (@MainActor @Sendable (NSApplication.ModalResponse) -> Void)?
    override func begin(completionHandler handler: @escaping @MainActor @Sendable (NSApplication.ModalResponse) -> Void) {
        completion = handler
        lastCompletion = handler
    }
    override func beginSheetModal(for window: NSWindow, completionHandler handler: @escaping @MainActor @Sendable (NSApplication.ModalResponse) -> Void) {
        begin(completionHandler: handler)
    }
    override func cancel(_ sender: Any?) {
        cancellations += 1
        if !deferCancellation { finishDeferredCancellation() }
    }
    func finishDeferredCancellation() {
        let callback = completion
        completion = nil
        callback?(.cancel)
    }
    func repeatLastResponse(_ response: NSApplication.ModalResponse) { lastCompletion?(response) }
}

@MainActor
private final class DownloadTestAlert: NSAlert {
    private var completion: (@MainActor @Sendable (NSApplication.ModalResponse) -> Void)?
    override func beginSheetModal(for window: NSWindow, completionHandler handler: (@MainActor @Sendable (NSApplication.ModalResponse) -> Void)? = nil) {
        completion = handler
    }
    func respond(_ response: NSApplication.ModalResponse) {
        let callback = completion
        completion = nil
        callback?(response)
    }
}
