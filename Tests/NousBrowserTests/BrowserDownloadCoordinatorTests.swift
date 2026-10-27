import Foundation
import Testing
@testable import NousBrowser

@Suite("Chosen download destinations")
struct BrowserDownloadCoordinatorTests {
    @Test func newFileOnlyAppearsAtTheChosenLocationAfterCompletion() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let chosen = folder.appendingPathComponent("My renamed video.mp4")
        let download = try BrowserDownloadDestination(url: chosen)
        defer { download.cancel() }
        #expect(!FileManager.default.fileExists(atPath: chosen.path))
        #expect(!FileManager.default.fileExists(atPath: download.stagingURL.path))
        #expect(download.stagingURL.deletingLastPathComponent().deletingLastPathComponent() == folder)
        let bytes = Data("synthetic completed download".utf8)
        try bytes.write(to: download.stagingURL)
        #expect(!FileManager.default.fileExists(atPath: chosen.path))
        try download.commit()
        #expect(try Data(contentsOf: chosen) == bytes)
        #expect(!FileManager.default.fileExists(atPath: download.stagingURL.deletingLastPathComponent().path))
        // Subsequent cleanup cannot remove the user's completed file.
        download.cancel()
        try download.commit()
        #expect(try Data(contentsOf: chosen) == bytes)
    }

    @Test func cancelOrFailurePreservesAnExistingFileAndRemovesOnlyStaging() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let chosen = folder.appendingPathComponent("existing.txt")
        let original = Data("original user's file".utf8)
        try original.write(to: chosen)
        let other = folder.appendingPathComponent("unrelated.txt")
        try original.write(to: other)
        let download = try BrowserDownloadDestination(url: chosen)
        try Data("partial download".utf8).write(to: download.stagingURL)
        #expect(try Data(contentsOf: chosen) == original)
        download.cancel()
        #expect(try Data(contentsOf: chosen) == original)
        #expect(try Data(contentsOf: other) == original)
        #expect(!FileManager.default.fileExists(atPath: download.stagingURL.deletingLastPathComponent().path))
    }

    @Test func successfulDownloadAtomicallyReplacesThePreviouslyChosenFile() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let chosen = folder.appendingPathComponent("replace.txt")
        try Data("old contents".utf8).write(to: chosen)
        let download = try BrowserDownloadDestination(url: chosen)
        defer { download.cancel() }
        let replacement = Data("new complete contents".utf8)
        try replacement.write(to: download.stagingURL)
        #expect(try String(contentsOf: chosen, encoding: .utf8) == "old contents")
        try download.commit()
        #expect(try Data(contentsOf: chosen) == replacement)
    }

    @Test(arguments: [false, true])
    func anotherWriterCannotBeOverwrittenWhileTheDownloadIsPending(originalExists: Bool) throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let chosen = folder.appendingPathComponent("conflict.txt")
        if originalExists { try Data("old".utf8).write(to: chosen) }
        let download = try BrowserDownloadDestination(url: chosen)
        defer { download.cancel() }
        try Data("downloaded".utf8).write(to: download.stagingURL)
        // Atomic write changes the file identity as well as its contents.
        try Data("a later edit".utf8).write(to: chosen, options: .atomic)
        #expect(throws: CocoaError.self) { try download.commit() }
        #expect(try String(contentsOf: chosen, encoding: .utf8) == "a later edit")
    }

    @Test func failedCommitDoesNotRemoveTheOriginalAndUnsafeTargetsAreRejected() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let chosen = folder.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: chosen)
        let download = try BrowserDownloadDestination(url: chosen)
        defer { download.cancel() }
        // A network failure never produced the expected staging file.
        #expect(throws: POSIXError.self) { try download.commit() }
        #expect(try String(contentsOf: chosen, encoding: .utf8) == "keep")
        let link = folder.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: chosen)
        #expect(throws: CocoaError.self) { _ = try BrowserDownloadDestination(url: link) }
        #expect(throws: CocoaError.self) { _ = try BrowserDownloadDestination(url: folder) }
        #expect(throws: CocoaError.self) { _ = try BrowserDownloadDestination(url: URL(string: "https://example.test/file")!) }
    }

    @Test @MainActor func filenamesRemainFilenamesAndKeepTheirMediaExtension() {
        #expect(BrowserDownloadCoordinator.filename("../../clip.mp4", hint: nil, mimeType: "video/mp4") == "clip.mp4")
        #expect(BrowserDownloadCoordinator.filename("folder\\picture.png", hint: nil, mimeType: "image/png") == "picture.png")
        #expect(BrowserDownloadCoordinator.filename("Unknown", hint: "my clip.mp4", mimeType: "video/mp4") == "my clip.mp4")
        #expect(BrowserDownloadCoordinator.filename("report", hint: nil, mimeType: "application/pdf") == "report.pdf")
        #expect(BrowserDownloadCoordinator.filename("..", hint: nil, mimeType: nil) == "download")
        #expect(BrowserDownloadCoordinator.filename("bad\u{0}name.txt", hint: nil, mimeType: nil) == "badname.txt")
    }

    @Test @MainActor func contextDownloadDoesNotStartUntilSaveAndCancellationIsFinal() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let chosen = folder.appendingPathComponent("selected.mp4")
        var started: [BrowserDownloadDestination] = []
        let cancelled = BrowserDownloadStartDecision { started.append($0) }
        #expect(started.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        try cancelled.choose(nil)
        // A late duplicate completion cannot start a cancelled request.
        try cancelled.choose(chosen)
        #expect(started.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

        let saved = BrowserDownloadStartDecision { started.append($0) }
        try saved.choose(chosen)
        try saved.choose(chosen)
        #expect(started.count == 1)
        #expect(started.first?.url == chosen)
        #expect(!FileManager.default.fileExists(atPath: chosen.path))
        started.forEach { $0.cancel() }
    }

    @Test @MainActor func contextDownloadRejectsInvalidDestinationBeforeNetworking() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var didStart = false
        let decision = BrowserDownloadStartDecision { _ in didStart = true }
        #expect(throws: CocoaError.self) { try decision.choose(folder) }
        #expect(!didStart)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test @MainActor func contextFilenameUsesHintOrURLAndDataMediaType() {
        #expect(BrowserDownloadCoordinator.filename(for: .init(url: URL(string: "https://example.test/clip.mp4?token=synthetic")!)) == "clip.mp4")
        #expect(BrowserDownloadCoordinator.filename(for: .init(url: URL(string: "https://example.test/download")!, suggestedFilename: "my video.mp4")) == "my video.mp4")
        #expect(BrowserDownloadCoordinator.filename(for: .init(url: URL(string: "https://example.test/")!)) == "download")
        #expect(BrowserDownloadCoordinator.filename(for: .init(url: URL(string: "data:image/png;base64,AAAA")!)) == "download.png")
        #expect(BrowserDownloadCoordinator.filename(for: .init(url: URL(string: "data:,hello")!)) == "download.txt")
        #expect(BrowserDownloadCoordinator.filename(for: .init(url: URL(string: "blob:https://example.test/1234")!)) == "download")
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NousDownloadTest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
