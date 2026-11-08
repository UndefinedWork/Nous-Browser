import Foundation
import Darwin
import UniformTypeIdentifiers

/// Filename normalization and same-volume atomic file installation for native
/// Chromium downloads. Network and Save-panel ownership live in the coordinator.
enum BrowserDownloadFilename {
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
