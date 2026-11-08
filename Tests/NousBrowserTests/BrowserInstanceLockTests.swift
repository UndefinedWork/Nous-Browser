import Darwin
import Foundation
import Testing
@testable import NousBrowser

@Suite("Per-distribution browser process lock")
struct BrowserInstanceLockTests {
    @Test func productionAndPreviewLocksDoNotConflict() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let production = BrowserRuntimePaths(distribution: .production, applicationSupport: directory, home: directory)
        let preview = BrowserRuntimePaths(distribution: .preview, applicationSupport: directory, home: directory)
        let productionLease = try #require(try BrowserInstanceLock.acquire(in: production.directory))
        let previewLease = try #require(try BrowserInstanceLock.acquire(in: preview.directory))
        defer { withExtendedLifetime((productionLease, previewLease)) {} }
        #expect(try BrowserInstanceLock.acquire(in: production.directory) == nil)
        #expect(try BrowserInstanceLock.acquire(in: preview.directory) == nil)
    }

    @Test func descriptorIsExclusivePrivateAndCloseOnExec() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = try #require(try BrowserInstanceLock.acquire(in: directory))
        defer { withExtendedLifetime(lease) {} }
        #expect(fcntl(lease.descriptor, F_GETFD) & FD_CLOEXEC != 0)
        #expect(try BrowserInstanceLock.acquire(in: directory) == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("engine.lock").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func releaseKeepsTheSameLockFileForNextProcess() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var first = try BrowserInstanceLock.acquire(in: directory)
        #expect(first != nil)
        let path = directory.appendingPathComponent("engine.lock").path
        let inode = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber
        first = nil
        let next = try #require(try BrowserInstanceLock.acquire(in: directory))
        defer { withExtendedLifetime(next) {} }
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber == inode)
    }

    @Test func invalidDirectoryAndSymlinkFailInsteadOfRunningUnlocked() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let regularFile = directory.appendingPathComponent("ordinary-file")
        let bytes = Data("synthetic existing file".utf8)
        try bytes.write(to: regularFile)
        #expect(throws: (any Error).self) { try BrowserInstanceLock.acquire(in: regularFile) }
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("engine.lock"), withDestinationURL: regularFile)
        #expect(throws: (any Error).self) { try BrowserInstanceLock.acquire(in: directory) }
        #expect(try Data(contentsOf: regularFile) == bytes)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nous-lock-tests-" + UUID().uuidString)
    }
}
