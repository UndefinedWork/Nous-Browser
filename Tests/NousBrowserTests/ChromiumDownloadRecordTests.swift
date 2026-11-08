import AppKit
import Testing
@testable import NousBrowser

@Suite("Chromium download ownership and destination safety")
@MainActor
struct ChromiumDownloadRecordTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nous-download-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test func saveIsOneShotAndCommitsOnlyTheActualNativeStagingPath() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("renamed.png")
        var choices: [URL] = []
        var canceled = 0
        let record = ChromiumDownloadRecord(id: "synthetic", filename: "image.png", sourceWindow: nil,
            choose: { choices.append($0) }, cancel: { canceled += 1 })
        record.receive(state: 0, received: 0, total: 4)
        #expect(record.state == .choosingDestination)
        #expect(choices.isEmpty)
        record.chooseDestination(final)
        record.chooseDestination(dir.appendingPathComponent("ignored.png"))
        #expect(choices.count == 1)
        let staging = try #require(choices.first)
        try Data([0, 1, 2, 3]).write(to: staging)
        #expect(!FileManager.default.fileExists(atPath: final.path))
        record.receive(state: 1, received: 4, total: 4, path: staging.path)
        #expect(record.state == .completed)
        #expect(try Data(contentsOf: final) == Data([0, 1, 2, 3]))
        #expect(canceled == 0)
        record.cancel()
        record.receive(state: 3, reason: 30)
        #expect(record.state == .completed)
        #expect(try Data(contentsOf: final) == Data([0, 1, 2, 3]))
    }

    @Test func cancelBeforeChoosingNeverCreatesDestinationOrStartsTransfer() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        var starts = 0, cancels = 0
        let record = ChromiumDownloadRecord(id: "cancel", filename: "video.mp4", sourceWindow: nil,
            choose: { _ in starts += 1 }, cancel: { cancels += 1 })
        record.chooseDestination(nil)
        record.chooseDestination(dir.appendingPathComponent("late.mp4"))
        record.cancel()
        #expect(record.state == .canceled)
        #expect(starts == 0 && cancels == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func interruptedOrCanceledDownloadsPreserveTheOriginal() throws {
        for terminal in [2, 3, 4] {
            let dir = try folder()
            defer { try? FileManager.default.removeItem(at: dir) }
            let final = dir.appendingPathComponent("existing.mp4")
            try Data("original".utf8).write(to: final)
            var staging: URL?
            var cancels = 0
            let record = ChromiumDownloadRecord(id: "terminal-\(terminal)", filename: "video.mp4", sourceWindow: nil,
                choose: { staging = $0 }, cancel: { cancels += 1 })
            record.chooseDestination(final)
            let path = try #require(staging)
            try Data("partial".utf8).write(to: path)
            record.receive(state: terminal, reason: 30)
            #expect(!record.state.isActive)
            #expect(cancels == 1)
            #expect(try String(contentsOf: final, encoding: .utf8) == "original")
            #expect(!FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
        }
    }

    @Test func sourceWindowIsNotRetainedAndConfirmedTransferCanFinish() throws {
        _ = NSApplication.shared
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        weak var weakWindow: NSWindow?
        let final = dir.appendingPathComponent("after-close.txt")
        var staging: URL?
        let record = ChromiumDownloadRecord(id: "source", filename: "file.txt", sourceWindow: nil,
            choose: { staging = $0 }, cancel: {})
        autoreleasepool {
            let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            weakWindow = window
            record.sourceWindow = window
            record.chooseDestination(final)
            window.close()
        }
        #expect(weakWindow == nil)
        #expect(record.sourceWindow == nil)
        let path = try #require(staging)
        try Data("complete".utf8).write(to: path)
        record.receive(state: 1, path: path.path)
        #expect(record.state == .completed)
        #expect(try String(contentsOf: final, encoding: .utf8) == "complete")
    }

    @Test func reentrantCancellationAndLateCompletionAreConsumedOnce() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("keep.txt")
        try Data("original".utf8).write(to: final)
        var record: ChromiumDownloadRecord!
        var staging: URL?
        var cancels = 0
        record = ChromiumDownloadRecord(id: "reentrant", filename: "keep.txt", sourceWindow: nil,
            choose: { staging = $0 }, cancel: {
                cancels += 1
                record.receive(state: 2)
                record.cancel()
            })
        record.chooseDestination(final)
        let path = try #require(staging)
        try Data("partial".utf8).write(to: path)
        record.cancel()
        record.receive(state: 1, path: path.path)
        #expect(cancels == 1)
        #expect(record.state == .canceled)
        #expect(try String(contentsOf: final, encoding: .utf8) == "original")
    }

    @Test func wrongCompletionPathAndDestinationChangedDuringDownloadFailSafely() throws {
        for wrongPath in [true, false] {
            let dir = try folder()
            defer { try? FileManager.default.removeItem(at: dir) }
            let final = dir.appendingPathComponent("chosen.txt")
            try Data("original".utf8).write(to: final)
            var staging: URL?
            let record = ChromiumDownloadRecord(id: "conflict", filename: "chosen.txt", sourceWindow: nil,
                choose: { staging = $0 }, cancel: {})
            record.chooseDestination(final)
            let path = try #require(staging)
            try Data("download".utf8).write(to: path)
            if !wrongPath { try Data("newer edit".utf8).write(to: final, options: .atomic) }
            record.receive(state: 1, path: wrongPath ? final.path : path.path)
            if case .failed = record.state {} else { Issue.record("Unsafe completion must fail") }
            #expect(try String(contentsOf: final, encoding: .utf8) == (wrongPath ? "original" : "newer edit"))
            #expect(!FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
        }
    }

    @Test func engineCancellationWithoutUserActionIsAFailureAndKeepsOriginal() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("existing.bin")
        try Data("original".utf8).write(to: final)
        var staging: URL?
        var canceled = 0
        let record = ChromiumDownloadRecord(id: "engine-canceled", filename: "download.bin", sourceWindow: nil,
            choose: { staging = $0 }, cancel: { canceled += 1 })
        record.chooseDestination(final)
        let path = try #require(staging)
        try Data("partial".utf8).write(to: path)
        record.receive(state: 2, reason: 40)
        if case .failed = record.state {} else { Issue.record("An engine cancellation is not a user cancellation") }
        #expect(canceled == 1)
        #expect(try String(contentsOf: final, encoding: .utf8) == "original")
        #expect(!FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
    }

    @Test func explicitSourceOrUserCancellationRemainsCanceled() {
        var canceled = 0
        let record = ChromiumDownloadRecord(id: "source-closed", filename: "file.bin", sourceWindow: nil,
            choose: { _ in Issue.record("Canceled choice must never start") }, cancel: { canceled += 1 })
        record.receive(state: 2, explicitCancellation: true)
        #expect(record.state == .canceled && canceled == 1)
        record.receive(state: 3, reason: 20)
        #expect(record.state == .canceled && canceled == 1)
    }
}
