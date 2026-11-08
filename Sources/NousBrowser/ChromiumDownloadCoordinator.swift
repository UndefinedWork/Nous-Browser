import AppKit
import Combine
import NousCore
import SwiftUI

/// Application-owned save queue and history. No job is owned by a page view,
/// so navigation and closing a source cannot discard a completed download.
@MainActor
final class ChromiumDownloadCoordinator: NSObject, ObservableObject {
    static let shared = ChromiumDownloadCoordinator()
    @Published private(set) var records: [ChromiumDownloadRecord] = []
    private var pending: [ChromiumDownloadRecord] = []
    private var activeChoice: ChromiumDownloadRecord?
    private var activePanel: NSSavePanel?
    private struct SaveDraft {
        let filename: String
        let directoryURL: URL?
    }
    private var saveDrafts: [String: SaveDraft] = [:]
    private var downloadsWindow: NSWindow?
    private var installed = false
    private var shuttingDown = false
    private var saveChoicesSuspended = false
    private var suspensionCompletion: (@MainActor () -> Void)?
    private var presentationScheduled = false
    private let makeSavePanel: @MainActor () -> NSSavePanel
    private let makeAlert: @MainActor () -> NSAlert
    private let showWindow: @MainActor (NSWindow) -> Void

    init(makeSavePanel: @escaping @MainActor () -> NSSavePanel = { NSSavePanel() },
         makeAlert: @escaping @MainActor () -> NSAlert = { NSAlert() },
         showWindow: @escaping @MainActor (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) }) {
        self.makeSavePanel = makeSavePanel
        self.makeAlert = makeAlert
        self.showWindow = showWindow
        super.init()
    }

    func start() {
        guard !installed else { return }
        installed = true
        NBChromiumDownloadCenter.shared().newDownloadHandler = { [weak self] job in
            MainActor.assumeIsolated { self?.accept(job) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
    }

    private func accept(_ job: NBChromiumDownloadJob) {
        guard !shuttingDown else { job.cancel(); return }
        let filename = BrowserDownloadFilename.filename(job.suggestedFilename, hint: nil, mimeType: job.mimeType)
        let record = ChromiumDownloadRecord(id: job.identifier, filename: filename,
            sourceWindow: job.sourceWindow,
            choose: { job.chooseDestination($0) }, cancel: { job.cancel() })
        // Both native and UI history retain only a small transfer object,
        // never the originating CefBrowser, WebContents, or NSView.
        job.updateHandler = { [weak self, weak record] job in
            MainActor.assumeIsolated {
                guard let self, let record else { return }
                let data = job.snapshot
                record.receive(state: (data["state"] as? NSNumber)?.intValue ?? 4,
                    received: (data["received"] as? NSNumber)?.int64Value ?? 0,
                    total: (data["total"] as? NSNumber)?.int64Value ?? 0,
                    path: data["path"] as? String,
                    reason: (data["reason"] as? NSNumber)?.intValue ?? 0,
                    sourceClosed: (data["sourceClosed"] as? NSNumber)?.boolValue ?? false,
                    explicitCancellation: (data["explicitCancellation"] as? NSNumber)?.boolValue ?? false)
                if !record.state.isActive {
                    self.pending.removeAll { $0.id == record.id }
                    self.saveDrafts.removeValue(forKey: record.id)
                    if self.activeChoice?.id == record.id { self.activePanel?.cancel(nil) }
                    if case .failed = record.state { self.showDownloads() }
                    self.trimHistory()
                }
            }
        }
        records.insert(record, at: 0)
        pending.append(record)
        presentNext()
    }

    private func presentNext() {
        guard !shuttingDown, !saveChoicesSuspended, activePanel == nil else { return }
        while !pending.isEmpty {
            let record = pending.removeFirst()
            let draft = saveDrafts.removeValue(forKey: record.id)
            guard record.state == .choosingDestination else { continue }
            let panel = makeSavePanel()
            panel.nameFieldStringValue = draft?.filename ?? record.filename
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.directoryURL = draft?.directoryURL
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            activePanel = panel
            activeChoice = record
            let completion: @MainActor @Sendable (NSApplication.ModalResponse) -> Void = { [weak self, weak panel, weak record] result in
                guard let self, let record, self.activePanel === panel else { return }
                self.activePanel = nil
                self.activeChoice = nil
                if ProcessInfo.processInfo.environment["NOUS_CHROMIUM_TRACE"] != nil {
                    NSLog("Nous download save result=%ld suspended=%d choosing=%d", result.rawValue,
                          self.saveChoicesSuspended, record.state == .choosingDestination)
                }
                // Dismissing a save sheet for beforeunload is not user Cancel.
                // Preserve its still-pending native callback until quit resolves.
                if !self.saveChoicesSuspended || result == .OK {
                    record.chooseDestination(result == .OK ? panel?.url : nil)
                }
                if record.state != .choosingDestination {
                    self.pending.removeAll { $0.id == record.id }
                    self.saveDrafts.removeValue(forKey: record.id)
                }
                if case .failed = record.state { self.showDownloads() }
                let suspended = self.suspensionCompletion
                self.suspensionCompletion = nil
                suspended?()
                self.schedulePresentation()
            }
            if let window = record.sourceWindow, window.isVisible, window.attachedSheet == nil {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else {
                // Never attach to an unrelated key window.
                panel.begin(completionHandler: completion)
            }
            return
        }
    }

    private func schedulePresentation() {
        guard !presentationScheduled, !shuttingDown, !saveChoicesSuspended else { return }
        presentationScheduled = true
        // Source-close can synchronously cancel several native jobs. Finish
        // that batch before considering its next queued Save sheet.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentationScheduled = false
            self.presentNext()
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        for record in records where record.sourceWindow === window && record.state == .choosingDestination {
            record.cancel()
            pending.removeAll { $0.id == record.id }
            saveDrafts.removeValue(forKey: record.id)
            if activeChoice?.id == record.id { activePanel?.cancel(nil) }
        }
        schedulePresentation()
    }

    var hasActiveDownloads: Bool { records.contains { $0.state.isActive } }

    func confirmTermination(completion: @escaping @MainActor (Bool) -> Void) {
        guard hasActiveDownloads else {
            // A page can initiate a download while beforeunload is pending.
            // Keep that future Save sheet from competing with the quit prompt.
            suspendSaveChoices { completion(true) }
            return
        }
        showDownloads()
        guard let window = downloadsWindow, window.attachedSheet == nil else {
            completion(false)
            return
        }
        let alert = makeAlert()
        alert.messageText = L10n.string("Downloads are still in progress")
        alert.informativeText = L10n.string("Quitting will cancel unfinished downloads.")
        alert.addButton(withTitle: L10n.string("Keep Downloading"))
        alert.addButton(withTitle: L10n.string("Quit and Cancel Downloads"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { completion(false); return }
            self.suspendSaveChoices { completion(true) }
        }
    }

    private func suspendSaveChoices(completion: @escaping @MainActor () -> Void) {
        saveChoicesSuspended = true
        guard let panel = activePanel else { completion(); return }
        if let record = activeChoice, record.state == .choosingDestination {
            // Canceling quit must restore the user's in-progress Save edits.
            // This is only panel state, never authorization to write a file.
            saveDrafts[record.id] = SaveDraft(filename: panel.nameFieldStringValue,
                                             directoryURL: panel.directoryURL)
            if !pending.contains(where: { $0.id == record.id }) {
                pending.insert(record, at: 0)
            }
        }
        suspensionCompletion = completion
        // Start beforeunload only from this sheet's completion, once AppKit
        // has detached it from the originating browser window.
        panel.cancel(nil)
    }

    func resumeAfterCancelledTermination() {
        guard !shuttingDown else { return }
        saveChoicesSuspended = false
        suspensionCompletion = nil
        schedulePresentation()
    }

    func shutdown() {
        shuttingDown = true
        suspensionCompletion = nil
        for record in records where record.state.isActive { record.cancel() }
        pending.removeAll()
        saveDrafts.removeAll()
        activePanel?.cancel(nil)
        NBChromiumDownloadCenter.shared().cancelAll()
    }

    func showDownloads() {
        if downloadsWindow == nil {
            let controller = NSHostingController(rootView: ChromiumDownloadsView(coordinator: self))
            let window = NSWindow(contentViewController: controller)
            window.title = L10n.string("Downloads")
            window.setContentSize(NSSize(width: 520, height: 420))
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            downloadsWindow = window
        }
        if let downloadsWindow { showWindow(downloadsWindow) }
    }

    func clearFinished() {
        records.removeAll { !$0.state.isActive }
    }

    private func trimHistory() {
        var finished = 0
        records.removeAll { record in
            guard !record.state.isActive else { return false }
            finished += 1
            return finished > 100
        }
    }
}

@MainActor
private struct ChromiumDownloadsView: View {
    @ObservedObject var coordinator: ChromiumDownloadCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.string("Downloads")).font(.title2.bold())
                Spacer()
                Button(L10n.string("Clear finished")) { coordinator.clearFinished() }
            }
            if coordinator.records.isEmpty {
                Spacer()
                Text(L10n.string("No downloads yet")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(coordinator.records) { ChromiumDownloadRow(record: $0) }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(22)
        .frame(minWidth: 420, minHeight: 240)
    }
}

@MainActor
private struct ChromiumDownloadRow: View {
    @ObservedObject var record: ChromiumDownloadRecord
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.document").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.finalURL?.lastPathComponent ?? record.filename).lineLimit(2)
                switch record.state {
                case .choosingDestination:
                    Text(L10n.string("Choose a save location")).foregroundStyle(.secondary)
                case .transferring:
                    if record.totalBytes > 0 {
                        ProgressView(value: Double(min(record.receivedBytes, record.totalBytes)), total: Double(record.totalBytes))
                    } else { ProgressView().controlSize(.small) }
                    Text(ByteCountFormatter.string(fromByteCount: record.receivedBytes, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                case .completed:
                    Text(L10n.string("Download complete")).foregroundStyle(.secondary)
                case .canceled:
                    Text(L10n.string("Canceled")).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).foregroundStyle(.red).font(.caption).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if record.state.isActive {
                Button { record.cancel() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help(L10n.string("Cancel"))
            } else if record.state == .completed, let url = record.finalURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help(L10n.string("Show in Finder"))
            }
        }
    }
}
