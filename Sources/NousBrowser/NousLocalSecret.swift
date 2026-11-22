import CryptoKit
import Darwin
import Foundation
import Security

/// A random secret kept in the user's Library (0600, in a 0700 folder).
///
/// Ad-hoc signed builds cannot share a keychain item: macOS ties the item to
/// the creating build's code hash, so the next update would need the login
/// password. Like WebKit's own website store, Nous instead keeps its keys in a
/// private file, so updates reopen the same profile and passwords silently.
nonisolated enum NousLocalSecret {
    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent("Secrets", isDirectory: true).appendingPathComponent("storage.key")
    }

    /// 32 random bytes, created once. Never synced or logged.
    static func load(in directory: URL, mayCreate: () throws -> Bool = { true }) throws -> Data {
        let file = url(in: directory)
        func readKey() throws -> Data {
            let data = try Data(contentsOf: file)
            guard data.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
            return data
        }
        do { return try readKey() }
        catch CocoaError.fileReadNoSuchFile {
            guard try mayCreate() else { throw CocoaError(.fileReadNoSuchFile) }
        }
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw BrowserPasswordStoreError.keychain(status) }
        // Publish a complete, private key without ever replacing a key created by another caller.
        var template = Array(folder.appendingPathComponent(".storage-key.XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let temporary = URL(fileURLWithFileSystemRepresentation: template, isDirectory: false, relativeTo: nil)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: bytes)
        try handle.close()
        do { try FileManager.default.linkItem(at: temporary, to: file) }
        catch CocoaError.fileWriteFileExists { return try readKey() }
        return bytes
    }

    /// Independent subkeys, so the Chromium secret never equals the vault key.
    static func derive(_ secret: Data, purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                               info: Data("nous:\(purpose)".utf8), outputByteCount: 32)
    }

    static func chromiumPassword(_ secret: Data) -> String {
        derive(secret, purpose: "chromium-safe-storage").withUnsafeBytes { Data($0).base64EncodedString() }
    }
}
