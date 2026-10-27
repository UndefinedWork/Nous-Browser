import AppKit
import Darwin
import UniformTypeIdentifiers
import WebKit

/// Owns downloads beyond their originating tab's lifetime. WebKit does not get
/// a writable destination until the user accepts the system save panel.
@MainActor
final class BrowserDownloadCoordinator: NSObject, WKDownloadDelegate {
    static let shared = BrowserDownloadCoordinator()

    private final class Job {
        let download: WKDownload
        weak var window: NSWindow?
        let filenameHint: String?
        var destination: BrowserDownloadDestination?
        var chooseDestination: (@MainActor @Sendable (URL?) -> Void)?
        var filename = "download"
        var destinationProvided = false

        init(download: WKDownload, window: NSWindow?, filenameHint: String?) {
            self.download = download
            self.window = window
            self.filenameHint = filenameHint
        }
    }

    private enum Choice: Equatable {
        case navigation(ObjectIdentifier)
        case start(UUID)
    }

    private final class StartChoice {
        let filename: String
        weak var window: NSWindow?
        let decision: BrowserDownloadStartDecision

        init(filename: String, window: NSWindow?, decision: BrowserDownloadStartDecision) {
            self.filename = filename
            self.window = window
            self.decision = decision
        }
    }

    private var jobs: [ObjectIdentifier: Job] = [:]
    private var starts: [UUID: StartChoice] = [:]
    private var pending: [Choice] = []
    private var activePanel: NSSavePanel?
    private var activeChoice: Choice?
    private var failures: [(Error, NSWindow?)] = []
    private var showingError = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
    }

    func accept(_ download: WKDownload, from webView: WKWebView, suggestedFilename: String? = nil) {
        track(download, from: webView, suggestedFilename: suggestedFilename, destination: nil)
    }

    /// Context-menu downloads have a known URL, so choose the destination before
    /// starting any request. Time spent in the Save panel cannot time out WebKit.
    func startDownload(request: BrowserWebView.DownloadRequest, from webView: WKWebView) {
        let id = UUID()
        let decision = BrowserDownloadStartDecision { [self, webView] destination in
            webView.startDownload(using: URLRequest(url: request.url)) { [self, webView, destination] download in
                track(download, from: webView, suggestedFilename: request.suggestedFilename,
                      destination: destination)
            }
        }
        starts[id] = StartChoice(filename: Self.filename(for: request), window: webView.window, decision: decision)
        pending.append(.start(id))
        presentNext()
    }

    private func track(_ download: WKDownload, from webView: WKWebView, suggestedFilename: String?,
                       destination: BrowserDownloadDestination?) {
        let id = ObjectIdentifier(download)
        guard jobs[id] == nil else { return }
        let job = Job(download: download, window: webView.window, filenameHint: suggestedFilename)
        job.destination = destination
        jobs[id] = job
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        let id = ObjectIdentifier(download)
        guard let job = jobs[id], job.chooseDestination == nil, !job.destinationProvided else {
            completionHandler(nil)
            return
        }
        if let destination = job.destination {
            job.destinationProvided = true
            completionHandler(destination.stagingURL)
            return
        }
        job.filename = Self.filename(suggestedFilename, hint: job.filenameHint, mimeType: response.mimeType)
        job.chooseDestination = completionHandler
        pending.append(.navigation(id))
        presentNext()
    }

    private func presentNext() {
        guard activePanel == nil, !showingError else { return }
        if !failures.isEmpty {
            let (error, window) = failures.removeFirst()
            let alert = NSAlert()
            alert.messageText = L10n.string("Download failed")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L10n.string("OK"))
            showingError = true
            if let window, window.isVisible, window.attachedSheet == nil {
                alert.beginSheetModal(for: window) { [weak self] _ in
                    self?.showingError = false
                    self?.presentNext()
                }
            } else {
                alert.runModal()
                showingError = false
                presentNext()
            }
            return
        }
        while !pending.isEmpty {
            let choice = pending.removeFirst()
            switch choice {
            case .start(let id):
                guard let start = starts[id] else { continue }
                presentPanel(for: choice, filename: start.filename, window: start.window) { [weak self] chosenURL in
                    guard let self, let start = self.starts.removeValue(forKey: id) else { return }
                    do {
                        try start.decision.choose(chosenURL)
                    } catch {
                        self.failures.append((error, start.window))
                    }
                }
            case .navigation(let id):
                guard let job = jobs[id], job.chooseDestination != nil else { continue }
                presentPanel(for: choice, filename: job.filename, window: job.window) { [weak self] chosenURL in
                    guard let self, let job = self.jobs[id], let choose = job.chooseDestination else { return }
                    job.chooseDestination = nil
                    if let url = chosenURL {
                        do {
                            let destination = try BrowserDownloadDestination(url: url)
                            job.destination = destination
                            job.destinationProvided = true
                            choose(destination.stagingURL)
                        } catch {
                            choose(nil)
                            self.jobs[id] = nil
                            self.failures.append((error, job.window))
                        }
                    } else {
                        choose(nil)
                        self.jobs[id] = nil
                    }
                }
            }
            return
        }
    }

    private func presentPanel(for choice: Choice, filename: String, window: NSWindow?,
                              chosen: @escaping @MainActor @Sendable (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        activePanel = panel
        activeChoice = choice
        let completion: @MainActor @Sendable (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] result in
            guard let self else { return }
            let chosenURL = result == .OK ? panel?.url : nil
            self.activePanel = nil
            self.activeChoice = nil
            chosen(chosenURL)
            self.presentNext()
        }
        // Never attach a download to an unrelated key window. If its source
        // already has another sheet, AppKit presents a separate save panel.
        if let window, window.isVisible, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else { panel.begin(completionHandler: completion) }
    }

    func downloadDidFinish(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        guard let job = jobs.removeValue(forKey: id) else { return }
        do { try job.destination?.commit() }
        catch {
            job.destination?.cancel()
            failures.append((error, job.window))
        }
        presentNext()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let id = ObjectIdentifier(download)
        guard let job = jobs.removeValue(forKey: id) else { return }
        let choose = job.chooseDestination
        job.chooseDestination = nil
        choose?(nil)
        job.destination?.cancel()
        pending.removeAll { $0 == .navigation(id) }
        let native = error as NSError
        if !(native.domain == NSURLErrorDomain && native.code == NSURLErrorCancelled),
           !(native.domain == NSCocoaErrorDomain && native.code == NSUserCancelledError) {
            failures.append((error, job.window))
        }
        if activeChoice == .navigation(id) { activePanel?.cancel(nil) }
        else { presentNext() }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let unstarted = starts.filter { $0.value.window === window }
        for (id, start) in unstarted {
            starts[id] = nil
            pending.removeAll { $0 == .start(id) }
            try? start.decision.choose(nil)
            if activeChoice == .start(id) { activePanel?.cancel(nil) }
        }
        // Confirmed downloads continue even if their tab or window closes.
        let unfinishedChoices = jobs.filter { $0.value.window === window && $0.value.destination == nil }
        for (id, job) in unfinishedChoices {
            jobs[id] = nil
            pending.removeAll { $0 == .navigation(id) }
            let choose = job.chooseDestination
            job.chooseDestination = nil
            if let choose { choose(nil) }
            else { job.download.cancel(nil) }
            if activeChoice == .navigation(id) { activePanel?.cancel(nil) }
        }
        presentNext()
    }

    static func filename(for request: BrowserWebView.DownloadRequest) -> String {
        let scheme = request.url.scheme?.lowercased()
        let hint = request.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let proposed = hint.flatMap { $0.isEmpty ? nil : $0 }
            ?? (["http", "https", "file"].contains(scheme ?? "") ? request.url.lastPathComponent : "download")
        let mimeType: String?
        if scheme == "data" {
            let declaredType = String(request.url.absoluteString.dropFirst(5).prefix { $0 != ";" && $0 != "," })
            mimeType = declaredType.isEmpty ? "text/plain" : declaredType
        } else { mimeType = nil }
        return filename(proposed, hint: nil, mimeType: mimeType)
    }

    static func filename(_ proposed: String, hint: String?, mimeType: String?) -> String {
        let hasSuggestion = !proposed.isEmpty && proposed != "Unknown" && proposed != "download"
        let source = hasSuggestion ? proposed : hint.flatMap { $0.isEmpty ? nil : $0 } ?? proposed
        var name = (source.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            .components(separatedBy: .controlCharacters).joined()
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || [".", "..", "/"].contains(name) { name = "download" }
        if (name as NSString).pathExtension.isEmpty,
           let mimeType, let suffix = UTType(mimeType: mimeType)?.preferredFilenameExtension {
            name += "." + suffix
        }
        return name
    }
}

/// A Save choice is consumed once. Cancellation does not create staging files
/// or invoke the network starter, even if AppKit later repeats its completion.
@MainActor
final class BrowserDownloadStartDecision {
    private var start: ((BrowserDownloadDestination) -> Void)?

    init(start: @escaping (BrowserDownloadDestination) -> Void) { self.start = start }

    func choose(_ url: URL?) throws {
        let start = self.start
        self.start = nil
        guard let start, let url else { return }
        start(try BrowserDownloadDestination(url: url))
    }
}

/// A completed download replaces the selected file in one same-volume rename.
/// The existing file is untouched while downloading, on cancellation or failure.
final class BrowserDownloadDestination {
    let url: URL
    let stagingURL: URL
    private let directory: URL
    private let original: FileStamp?
    private let scopedAccess: Bool
    private var finished = false

    init(url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileWriteInvalidFileName) }
        self.url = url.standardizedFileURL
        scopedAccess = url.startAccessingSecurityScopedResource()
        do { original = try Self.stamp(at: self.url) }
        catch {
            if scopedAccess { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        directory = self.url.deletingLastPathComponent().appendingPathComponent(".nous-download-" + UUID().uuidString, isDirectory: true)
        stagingURL = directory.appendingPathComponent(self.url.lastPathComponent)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700]) }
        catch {
            if scopedAccess { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func commit() throws {
        guard !finished else { return }
        guard try Self.stamp(at: url) == original else { throw CocoaError(.fileWriteFileExists) }
        // RENAME_EXCL also guards creation races after the preceding check.
        let result = original == nil
            ? renamex_np(stagingURL.path, url.path, UInt32(RENAME_EXCL))
            : rename(stagingURL.path, url.path)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        cancel()
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        try? FileManager.default.removeItem(at: directory)
        if scopedAccess { url.stopAccessingSecurityScopedResource() }
    }

    private struct FileStamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
    }

    private static func stamp(at url: URL) throws -> FileStamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw CocoaError(.fileWriteInvalidFileName) }
        return FileStamp(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                         modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
                         changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec)
    }
}
