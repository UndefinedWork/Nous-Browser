import Darwin
import Foundation

/// One process owns each distribution's shared session and Chromium profile.
/// Acquire before credentials or CEF initialize, and hold until process exit.
@MainActor
enum BrowserInstanceLock {
    // Deliberately no finish/release API: applicationWillTerminate is too early.
    // The descriptor remains owned until process exit releases the kernel lock.
    private static var lifetimeLease: Lease?

    static func start() throws -> Bool {
        guard BrowserRuntimePaths.currentDistribution != nil else { throw CocoaError(.executableLoad) }
        if lifetimeLease != nil { return true }
        guard let lease = try acquire(in: BrowserRuntimePaths.current.directory) else {
            return false
        }
        lifetimeLease = lease
        return true
    }

    /// Separate acquisition permits real process tests with a temporary folder.
    /// A missing/invalid/unwritable file is an error, never permission to proceed.
    nonisolated static func acquire(in directory: URL) throws -> Lease? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("engine.lock").path
        let fd = path.withCString { open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)) }
        guard fd >= 0 else { throw posixError() }
        var retained = false
        defer { if !retained { close(fd) } }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw posixError() }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(), metadata.st_nlink == 1 else {
            throw POSIXError(.EPERM)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            if failure == EWOULDBLOCK || failure == EAGAIN { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        guard fchmod(fd, mode_t(0o600)) == 0 else { throw posixError() }
        retained = true
        return Lease(descriptor: fd)
    }

    nonisolated private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    nonisolated final class Lease {
        let descriptor: Int32
        fileprivate init(descriptor: Int32) { self.descriptor = descriptor }
        deinit { close(descriptor) }
    }
}
