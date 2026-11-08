import AppKit
import Combine
import Foundation
import Observation

nonisolated struct LibraryCapture: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case screenshot, recording }
    let kind: Kind
    let url: URL
    let created: Date
    let size: Int64
    /// Still arriving from iCloud.
    let isPlaceholder: Bool

    var id: String { kind.rawValue + "/" + url.lastPathComponent }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var page: NativePage { kind == .screenshot ? .screenshot(url.lastPathComponent) : .recording(url.lastPathComponent) }
}

nonisolated struct LibraryDownload: Codable, Identifiable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case completed, failed, canceled }
    var id: String
    var filename: String
    var path: String?
    var size: Int64
    var date: Date
    var state: State
    var message: String?
    var device: String
}

/// Screenshots, recordings, history and downloads, kept in iCloud Drive when it
/// is available (no CloudKit entitlement is needed for a Drive folder). Each Mac
/// writes its own history/download file, so devices never overwrite each other.
@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore()
    static let syncDefaultsKey = "NousLibraryICloudSync"

    private(set) var captures: [LibraryCapture] = []
    private(set) var downloads: [LibraryDownload] = []
    private(set) var remoteHistory: [BrowserHistoryEntry] = []
    /// Including removal tombstones; see `bookmarks`.
    var bookmarkRecords: [String: LibraryBookmark] = [:]
    private(set) var root: URL
    private(set) var isUsingICloud = false
    /// Bumped when an edited preview is written, so thumbnails reload.
    private(set) var previewRevision = 0

    var syncsWithICloud: Bool {
        didSet {
            guard oldValue != syncsWithICloud else { return }
            UserDefaults.standard.set(syncsWithICloud, forKey: Self.syncDefaultsKey)
            relocate()
        }
    }

    @ObservationIgnored private var downloadsCancellable: AnyCancellable?
    @ObservationIgnored private var recordCancellables: [String: AnyCancellable] = [:]
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private weak var history: BrowserHistoryStore?
    @ObservationIgnored private var historySaveTask: Task<Void, Never>?
    @ObservationIgnored private var lastHistorySnapshot: [BrowserHistoryEntry] = []
    @ObservationIgnored let deviceID: String

    nonisolated static var iCloudDriveRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }
    nonisolated static var localRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nous Browser/Library", isDirectory: true)
    }
    nonisolated static var iCloudDriveAvailable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: iCloudDriveRoot.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private init() {
        let defaults = UserDefaults.standard
        syncsWithICloud = defaults.object(forKey: Self.syncDefaultsKey) == nil || defaults.bool(forKey: Self.syncDefaultsKey)
        if let saved = defaults.string(forKey: "NousLibraryDeviceID") { deviceID = saved }
        else {
            let created = (Host.current().localizedName ?? "Mac") + " " + UUID().uuidString.prefix(8)
            defaults.set(created, forKey: "NousLibraryDeviceID")
            deviceID = created
        }
        root = Self.localRoot
        relocate()
    }

    var screenshotsFolder: URL { root.appendingPathComponent("Screenshots", isDirectory: true) }
    var recordingsFolder: URL { root.appendingPathComponent("Recordings", isDirectory: true) }
    // iCloud Drive does not sync dot-files, so app data lives in a plain folder.
    private var dataFolder: URL { root.appendingPathComponent("Data", isDirectory: true) }
    private var editsFolder: URL { dataFolder.appendingPathComponent("Edits", isDirectory: true) }
    private var historyFolder: URL { dataFolder.appendingPathComponent("History", isDirectory: true) }
    private var downloadsFolder: URL { dataFolder.appendingPathComponent("Downloads", isDirectory: true) }
    private var bookmarksFolder: URL { dataFolder.appendingPathComponent("Bookmarks", isDirectory: true) }
    private var deviceFileName: String { deviceID.replacingOccurrences(of: "/", with: "-") + ".json" }

    /// iCloud Drive first; the local folder when Drive is off or turned off here.
    /// The isolated preview build keeps a QA session's Library beside it, never in iCloud.
    private static var qaRoot: URL? {
        guard Bundle.main.bundleIdentifier?.hasSuffix(".chromium-preview") == true,
              let session = ProcessInfo.processInfo.environment["NOUS_BROWSER_PREVIEW_SESSION"] else { return nil }
        return URL(fileURLWithPath: session).deletingLastPathComponent().appendingPathComponent("Library", isDirectory: true)
    }

    private func relocate() {
        let useCloud = syncsWithICloud && Self.iCloudDriveAvailable && Self.qaRoot == nil
        let target = Self.qaRoot ?? (useCloud ? Self.iCloudDriveRoot.appendingPathComponent("Nous Browser", isDirectory: true) : Self.localRoot)
        let previous = root
        root = target
        isUsingICloud = useCloud
        for folder in [screenshotsFolder, recordingsFolder, editsFolder, historyFolder, downloadsFolder, bookmarksFolder] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        if previous != target {
            migrate(from: previous)
            // Carry this Mac's bookmarks to the new place.
            if !bookmarkRecords.isEmpty { saveBookmarks() }
        }
        refresh()
    }

    /// Moving between local and iCloud carries existing items along.
    private func migrate(from previous: URL) {
        let manager = FileManager.default
        for folder in ["Screenshots", "Recordings", "Data/Edits"] {
            let source = previous.appendingPathComponent(folder, isDirectory: true)
            guard let items = try? manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { continue }
            for item in items {
                let destination = root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(item.lastPathComponent)
                guard !manager.fileExists(atPath: destination.path) else { continue }
                try? manager.moveItem(at: item, to: destination)
            }
        }
    }

    func start(history: BrowserHistoryStore) {
        self.history = history
        downloadsCancellable = ChromiumDownloadCoordinator.shared.$records.sink { [weak self] records in
            MainActor.assumeIsolated { self?.observe(records) }
        }
        observeHistory()
        refresh()
        // iCloud delivers items from other Macs at any time.
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: Captures

    func refresh() {
        let manager = FileManager.default
        var found: [LibraryCapture] = []
        for (kind, folder) in [(LibraryCapture.Kind.screenshot, screenshotsFolder), (.recording, recordingsFolder)] {
            guard let items = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                                                               options: []) else { continue }
            for item in items {
                var name = item.lastPathComponent
                var placeholder = false
                // iCloud keeps not-yet-downloaded files as ".name.icloud".
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    name = String(name.dropFirst().dropLast(7))
                    placeholder = true
                    try? manager.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(name))
                } else if name.hasPrefix(".") { continue }
                let ext = (name as NSString).pathExtension.lowercased()
                guard kind == .screenshot ? ["png", "jpg", "jpeg", "heic"].contains(ext) : ["mp4", "mov", "m4v"].contains(ext) else { continue }
                let values = try? item.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                found.append(LibraryCapture(kind: kind, url: folder.appendingPathComponent(name),
                                            created: values?.creationDate ?? .distantPast,
                                            size: Int64(values?.fileSize ?? 0), isPlaceholder: placeholder))
            }
        }
        found.sort { $0.created > $1.created }
        if found != captures { captures = found }
        loadRemote()
    }

    func capture(for page: NativePage) -> LibraryCapture? {
        switch page {
        case .screenshot(let file): captures.first { $0.kind == .screenshot && $0.url.lastPathComponent == file }
            ?? existing(.screenshot, file)
        case .recording(let file): captures.first { $0.kind == .recording && $0.url.lastPathComponent == file }
            ?? existing(.recording, file)
        case .library: nil
        }
    }

    private func existing(_ kind: LibraryCapture.Kind, _ file: String) -> LibraryCapture? {
        let url = (kind == .screenshot ? screenshotsFolder : recordingsFolder).appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return LibraryCapture(kind: kind, url: url, created: Date(), size: 0, isPlaceholder: false)
    }

    nonisolated static func fileName(prefix: String, date: Date = Date(), extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(formatter.string(from: date)).\(ext)"
    }

    func uniqueURL(in folder: URL, name: String) -> URL {
        let manager = FileManager.default
        let first = folder.appendingPathComponent(name)
        guard manager.fileExists(atPath: first.path) else { return first }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let candidate = folder.appendingPathComponent("\(base) \(index)").appendingPathExtension(ext)
            if !manager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    @discardableResult
    func saveScreenshot(_ png: Data) throws -> LibraryCapture {
        let url = uniqueURL(in: screenshotsFolder, name: Self.fileName(prefix: L10n.string("Screenshot"), extension: "png"))
        try png.write(to: url, options: .atomic)
        refresh()
        return captures.first { $0.url == url } ?? LibraryCapture(kind: .screenshot, url: url, created: Date(), size: Int64(png.count), isPlaceholder: false)
    }

    @discardableResult
    func importRecording(_ temporary: URL, startedAt: Date) throws -> LibraryCapture {
        let url = uniqueURL(in: recordingsFolder, name: Self.fileName(prefix: L10n.string("Recording"), date: startedAt, extension: "mp4"))
        try FileManager.default.moveItem(at: temporary, to: url)
        refresh()
        return captures.first { $0.url == url } ?? LibraryCapture(kind: .recording, url: url, created: startedAt, size: 0, isPlaceholder: false)
    }

    func delete(_ capture: LibraryCapture) {
        try? FileManager.default.trashItem(at: capture.url, resultingItemURL: nil)
        try? FileManager.default.removeItem(at: editURL(for: capture))
        try? FileManager.default.removeItem(at: previewURL(for: capture))
        refresh()
    }

    func rename(_ capture: LibraryCapture, to name: String) -> LibraryCapture? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !trimmed.isEmpty else { return nil }
        let destination = capture.url.deletingLastPathComponent().appendingPathComponent(trimmed)
            .appendingPathExtension(capture.url.pathExtension)
        guard destination != capture.url, !FileManager.default.fileExists(atPath: destination.path) else { return nil }
        do {
            try FileManager.default.moveItem(at: capture.url, to: destination)
            let edit = editURL(for: capture)
            if FileManager.default.fileExists(atPath: edit.path) {
                try? FileManager.default.moveItem(at: edit, to: editsFolder.appendingPathComponent(capture.kind.rawValue + "-" + destination.lastPathComponent + ".json"))
            }
        } catch { return nil }
        refresh()
        return captures.first { $0.url == destination }
    }

    /// The editor's non-destructive state, beside the original capture.
    func editURL(for capture: LibraryCapture) -> URL {
        editsFolder.appendingPathComponent(capture.kind.rawValue + "-" + capture.url.lastPathComponent + ".json")
    }

    /// The edited look, for Library thumbnails.
    func previewURL(for capture: LibraryCapture) -> URL {
        editsFolder.appendingPathComponent(capture.kind.rawValue + "-" + capture.url.lastPathComponent + ".preview.png")
    }

    func savePreview(_ png: Data, for capture: LibraryCapture) {
        try? png.write(to: previewURL(for: capture), options: .atomic)
        previewRevision += 1
    }

    func loadEdit<T: Decodable>(_ type: T.Type, for capture: LibraryCapture) -> T? {
        guard let data = try? Data(contentsOf: editURL(for: capture)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func saveEdit<T: Encodable>(_ value: T, for capture: LibraryCapture) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: editURL(for: capture), options: .atomic)
    }

    // MARK: Downloads

    private func observe(_ records: [ChromiumDownloadRecord]) {
        for record in records where recordCancellables[record.id] == nil {
            recordCancellables[record.id] = record.$state.sink { [weak self, weak record] state in
                MainActor.assumeIsolated {
                    guard let self, let record else { return }
                    self.recordFinished(record, state: state)
                }
            }
        }
    }

    private func recordFinished(_ record: ChromiumDownloadRecord, state: ChromiumDownloadRecord.State) {
        let stored: LibraryDownload.State
        var message: String?
        switch state {
        case .completed: stored = .completed
        case .canceled: stored = .canceled
        case .failed(let text): stored = .failed; message = text
        default: return
        }
        guard !downloads.contains(where: { $0.id == record.id }) else { return }
        let url = record.finalURL
        let size = url.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init) ?? record.receivedBytes
        downloads.insert(LibraryDownload(id: record.id, filename: url?.lastPathComponent ?? record.filename, path: url?.path,
                                         size: size, date: Date(), state: stored, message: message, device: deviceID), at: 0)
        saveDeviceFile(downloads.filter { $0.device == deviceID }.prefix(500).map { $0 }, folder: downloadsFolder)
    }

    func removeDownload(_ id: String) {
        downloads.removeAll { $0.id == id }
        saveDeviceFile(downloads.filter { $0.device == deviceID }, folder: downloadsFolder)
    }

    func clearDownloads() {
        downloads.removeAll { $0.device == deviceID }
        ChromiumDownloadCoordinator.shared.clearFinished()
        saveDeviceFile([LibraryDownload](), folder: downloadsFolder)
    }

    // MARK: History

    private func observeHistory() {
        guard let history else { return }
        withObservationTracking { _ = history.entries } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleHistoryExport()
                self?.observeHistory()
            }
        }
        scheduleHistoryExport()
    }

    private func scheduleHistoryExport() {
        historySaveTask?.cancel()
        historySaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, let history = self.history else { return }
            let entries = Array(history.entries.prefix(1000))
            guard entries != self.lastHistorySnapshot else { return }
            self.lastHistorySnapshot = entries
            self.saveDeviceFile(entries, folder: self.historyFolder)
        }
    }

    func saveBookmarks() {
        saveDeviceFile(Array(bookmarkRecords.values), folder: bookmarksFolder)
    }

    private func loadBookmarks() {
        let decoder = JSONDecoder()
        let own = (try? decoder.decode([LibraryBookmark].self,
            from: Data(contentsOf: bookmarksFolder.appendingPathComponent(deviceFileName)))) ?? []
        let others = deviceFiles(in: bookmarksFolder).compactMap {
            try? decoder.decode([LibraryBookmark].self, from: Data(contentsOf: $0))
        }
        let merged = LibraryBookmark.merge([own, Array(bookmarkRecords.values)] + others)
        if merged != bookmarkRecords { bookmarkRecords = merged }
        // Keep this Mac's file a complete copy, so any one file restores everything.
        if merged != LibraryBookmark.merge([own]) { saveBookmarks() }
    }

    /// The other Macs' history and downloads.
    private func loadRemote() {
        loadBookmarks()
        var history: [BrowserHistoryEntry] = []
        for file in deviceFiles(in: historyFolder) {
            if let entries = try? JSONDecoder().decode([BrowserHistoryEntry].self, from: Data(contentsOf: file)) { history += entries }
        }
        if history != remoteHistory { remoteHistory = history }
        var remoteDownloads: [LibraryDownload] = []
        for file in deviceFiles(in: downloadsFolder) {
            if let items = try? JSONDecoder().decode([LibraryDownload].self, from: Data(contentsOf: file)) { remoteDownloads += items }
        }
        if downloads.isEmpty || !remoteDownloads.isEmpty {
            let local = downloads.filter { $0.device == deviceID }
            let ownFile = downloadsFolder.appendingPathComponent(deviceFileName)
            let own = local.isEmpty ? ((try? JSONDecoder().decode([LibraryDownload].self, from: Data(contentsOf: ownFile))) ?? []) : local
            let merged = (own + remoteDownloads).sorted { $0.date > $1.date }
            if merged != downloads { downloads = merged }
        }
    }

    private func deviceFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != deviceFileName }
    }

    private func saveDeviceFile<T: Encodable>(_ value: T, folder: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: folder.appendingPathComponent(deviceFileName), options: .atomic)
    }

    /// Local entries first; another Mac's visit to the same page adds to it.
    func mergedHistory(local: [BrowserHistoryEntry]) -> [BrowserHistoryEntry] {
        var byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in remoteHistory {
            if let existing = byID[entry.id] {
                if entry.lastVisited > existing.lastVisited { byID[entry.id] = entry }
            } else { byID[entry.id] = entry }
        }
        return byID.values.sorted { $0.lastVisited > $1.lastVisited }
    }
}
