import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Scheme, exact host and effective port; never matches parent/subdomains.
nonisolated struct PasswordOrigin: Hashable, Codable, Sendable, CustomStringConvertible {
    let description: String
    var url: URL { URL(string: description)! }

    init?(string: String) {
        guard !string.isEmpty, !string.contains("\\"),
              !string.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 32 || $0.value == 127 }),
              let url = URL(string: string) else { return nil }
        self.init(url: url)
    }

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil,
              !url.absoluteString.contains("\\"),
              !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 32 || $0.value == 127 }),
              !(host.contains("%") || host.contains("/") || host.contains("@")),
              url.port.map({ (0...65535).contains($0) }) ?? true else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        let defaultPort = scheme == "https" ? 443 : 80
        components.port = url.port == defaultPort ? nil : url.port
        guard let normalized = components.url?.absoluteString else { return nil }
        description = normalized
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let origin = PasswordOrigin(string: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid password origin")
        }
        self = origin
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

nonisolated struct BrowserPasswordCredential: Codable, Equatable, Sendable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    let title: String
    let url: URL
    let origin: PasswordOrigin
    let username: String
    let password: String
    // CSV notes and OTP seeds are deliberately not collected.
    let notes: String
    let otpAuth: String

    var id: String {
        let value = origin.description + "\u{0}" + username
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var description: String { "BrowserPasswordCredential(<redacted>)" }
    var debugDescription: String { description }

    init?(title: String, url: URL, username: String, password: String) {
        guard let origin = PasswordOrigin(url: url), !password.isEmpty else { return nil }
        self.title = title
        self.url = url
        self.origin = origin
        self.username = username
        self.password = password
        notes = ""
        otpAuth = ""
    }
}

nonisolated struct BrowserPasswordSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let username: String
    let origin: PasswordOrigin
}

nonisolated struct BrowserPasswordImportResult: Equatable, Sendable {
    let imported: Int
    let updated: Int
    let skipped: Int
    let duplicates: Int
    let total: Int
}

nonisolated struct BrowserPasswordParsedCSV: Sendable {
    let credentials: [BrowserPasswordCredential]
    let skipped: Int
    let duplicates: Int
}

nonisolated enum BrowserPasswordStoreError: Error, Equatable, LocalizedError {
    case invalidCSV, unsupportedCSV, fileTooLarge, corruptVault, credentialNotFound
    case authenticationUnavailable, authenticationFailed
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidCSV, .unsupportedCSV: return L10n.string("The password CSV file could not be read.")
        case .fileTooLarge: return L10n.string("The password file is too large.")
        case .corruptVault: return L10n.string("Saved passwords could not be read. Your existing data was not replaced.")
        case .credentialNotFound: return L10n.string("The saved account is no longer available.")
        case .authenticationUnavailable: return L10n.string("Set up a Mac login password to use saved passwords.")
        case .authenticationFailed: return L10n.string("Device verification was not completed.")
        case .keychain(let status): return L10n.format("Password storage failed (%d).", status)
        }
    }
}

nonisolated enum BrowserPasswordCSV {
    static let maximumBytes = 10 * 1024 * 1024
    static let maximumRecords = 10_000

    static func parse(_ data: Data) throws -> BrowserPasswordParsedCSV {
        guard data.count <= maximumBytes else { throw BrowserPasswordStoreError.fileTooLarge }
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) { text = utf8 }
        else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
                let utf16 = String(data: data, encoding: .utf16) { text = utf16 }
        else { throw BrowserPasswordStoreError.invalidCSV }
        let content = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let rows = try records(Array(content.utf8))
        guard let header = rows.first else { throw BrowserPasswordStoreError.unsupportedCSV }
        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard Set(names).count == names.count,
              let urlIndex = names.firstIndex(of: "url"),
              let usernameIndex = names.firstIndex(of: "username"),
              let passwordIndex = names.firstIndex(of: "password") else { throw BrowserPasswordStoreError.unsupportedCSV }
        let titleIndex = names.firstIndex(of: "title") ?? names.firstIndex(of: "name")
        var credentials: [BrowserPasswordCredential] = []
        var indices: [String: Int] = [:]
        var skipped = 0
        var duplicates = 0
        for row in rows.dropFirst() {
            if row.allSatisfy(\.isEmpty) { continue }
            guard row.count == names.count,
                  let origin = PasswordOrigin(string: row[urlIndex]),
                  let url = URL(string: row[urlIndex]),
                  let credential = BrowserPasswordCredential(title: titleIndex.map { row[$0] } ?? origin.description,
                                                              url: url, username: row[usernameIndex], password: row[passwordIndex]) else {
                skipped += 1
                continue
            }
            if let index = indices[credential.id] {
                credentials[index] = credential
                duplicates += 1
            } else {
                indices[credential.id] = credentials.count
                credentials.append(credential)
            }
        }
        return .init(credentials: credentials, skipped: skipped, duplicates: duplicates)
    }

    /// RFC 4180 quoting, escaped quotes, embedded newlines and CRLF.
    private static func records(_ bytes: [UInt8]) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var quoted = false
        var closedQuote = false
        var index = 0
        func appendField() {
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
            closedQuote = false
        }
        func appendRow() throws {
            if !row.allSatisfy(\.isEmpty) {
                // Count every nonempty data row, including invalid/duplicate
                // ones, and stop during parsing rather than after allocation.
                guard rows.count < maximumRecords + 1 else { throw BrowserPasswordStoreError.fileTooLarge }
                rows.append(row)
            }
            row.removeAll(keepingCapacity: true)
        }
        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                if byte == 34 {
                    if index + 1 < bytes.count, bytes[index + 1] == 34 { field.append(34); index += 1 }
                    else { quoted = false; closedQuote = true }
                } else { field.append(byte) }
            } else if byte == 44 {
                appendField()
            } else if byte == 10 || byte == 13 {
                appendField()
                try appendRow()
                if byte == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
            } else if byte == 34 {
                guard field.isEmpty, !closedQuote else { throw BrowserPasswordStoreError.invalidCSV }
                quoted = true
            } else {
                guard !closedQuote else { throw BrowserPasswordStoreError.invalidCSV }
                field.append(byte)
            }
            index += 1
        }
        guard !quoted else { throw BrowserPasswordStoreError.invalidCSV }
        if !field.isEmpty || !row.isEmpty || closedQuote { appendField(); try appendRow() }
        return rows
    }
}

protocol BrowserPasswordVaultBackend: Sendable {
    func load() async throws -> Data?
    /// Must replace the complete value atomically, without deleting on failure.
    func save(_ data: Data) async throws
}

@MainActor
protocol BrowserPasswordAuthenticating {
    func authenticate(reason: String) async throws
}

@MainActor
final class BrowserPasswordDeviceAuthentication: BrowserPasswordAuthenticating {
    func authenticate(reason: String) async throws {
        let context = LAContext()
        defer { context.invalidate() }
        context.localizedCancelTitle = L10n.string("Cancel")
        context.touchIDAuthenticationAllowableReuseDuration = 0
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if let error { throw error }
            throw BrowserPasswordStoreError.authenticationUnavailable
        }
        let invalidate: @MainActor @Sendable () -> Void = { context.invalidate() }
        // LAError (including userCancel/appCancel) is intentionally propagated.
        let verified = try await withTaskCancellationHandler {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } onCancel: {
            Task { @MainActor in invalidate() }
        }
        guard verified else { throw BrowserPasswordStoreError.authenticationFailed }
        try Task.checkCancellation()
    }
}

/// Current releases are ad-hoc signed. The file-based login keychain uses its
/// normal application ACL; device verification is enforced by the store above
/// every read/write. This is deliberately not advertised as a DP/userPresence
/// item, which requires provisioned code-signing entitlements on macOS.
actor BrowserPasswordKeychainBackend: BrowserPasswordVaultBackend {
    private let service: String
    private let account: String

    init(service: String = "com.nous.browser.password-vault", account: String = "vault-v1") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: false]
    }

    func load() throws -> Data? {
        try Task.checkCancellation()
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw BrowserPasswordStoreError.keychain(status) }
        guard let data = result as? Data else { throw BrowserPasswordStoreError.corruptVault }
        return data
    }

    func save(_ data: Data) throws {
        try Task.checkCancellation()
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrLabel as String] = "Nous Browser"
            let added = SecItemAdd(request as CFDictionary, nil)
            guard added == errSecSuccess else { throw BrowserPasswordStoreError.keychain(added) }
        } else if status != errSecSuccess { throw BrowserPasswordStoreError.keychain(status) }
    }
}

@MainActor
final class BrowserPasswordStore {
    static let shared: BrowserPasswordStore = {
        #if DEBUG
        if let identifier = Bundle.main.bundleIdentifier,
           identifier.hasPrefix("com.cellier.nous-browser.") {
            // Isolated UI review apps must never open the installed app's vault.
            return BrowserPasswordStore(backend: BrowserPasswordKeychainBackend(service: identifier + ".password-vault"))
        }
        #endif
        return BrowserPasswordStore()
    }()
    private let backend: any BrowserPasswordVaultBackend
    private let authentication: any BrowserPasswordAuthenticating
    private let maximumVaultBytes: Int
    private var importing = false
    private var importWaiters: [CheckedContinuation<Void, Never>] = []

    init(backend: any BrowserPasswordVaultBackend = BrowserPasswordKeychainBackend(),
         authentication: any BrowserPasswordAuthenticating = BrowserPasswordDeviceAuthentication(),
         maximumVaultBytes: Int = 32 * 1024 * 1024) {
        self.backend = backend
        self.authentication = authentication
        // Tests may lower the limit, but no caller can exceed the production cap.
        self.maximumVaultBytes = min(32 * 1024 * 1024, max(0, maximumVaultBytes))
    }

    func credentials(for origin: PasswordOrigin, reason: String) async throws -> [BrowserPasswordCredential] {
        try Task.checkCancellation()
        try await authentication.authenticate(reason: reason)
        try Task.checkCancellation()
        let credentials = try await loadVault()
        try Task.checkCancellation()
        return credentials.filter { $0.origin == origin }
    }

    func summaries(forOrigin origin: PasswordOrigin, reason: String) async throws -> [BrowserPasswordSummary] {
        try await credentials(for: origin, reason: reason).map {
            .init(id: $0.id, title: $0.title, username: $0.username, origin: $0.origin)
        }
    }

    func read(_ id: String, reason: String) async throws -> BrowserPasswordCredential {
        try Task.checkCancellation()
        try await authentication.authenticate(reason: reason)
        try Task.checkCancellation()
        let credentials = try await loadVault()
        try Task.checkCancellation()
        guard let credential = credentials.first(where: { $0.id == id }) else { throw BrowserPasswordStoreError.credentialNotFound }
        return credential
    }

    func importCSV(_ data: Data, reason: String) async throws -> BrowserPasswordImportResult {
        let parsed = try BrowserPasswordCSV.parse(data)
        await acquireImport()
        defer { releaseImport() }
        try Task.checkCancellation()
        try await authentication.authenticate(reason: reason)
        try Task.checkCancellation()
        var credentials = try await loadVault()
        try Task.checkCancellation()
        var indices = Dictionary(uniqueKeysWithValues: credentials.enumerated().map { ($0.element.id, $0.offset) })
        var imported = 0
        var updated = 0
        var duplicates = parsed.duplicates
        for credential in parsed.credentials {
            if let index = indices[credential.id] {
                if credentials[index] == credential { duplicates += 1 }
                else { credentials[index] = credential; updated += 1 }
            } else {
                indices[credential.id] = credentials.count
                credentials.append(credential)
                imported += 1
            }
        }
        if imported > 0 || updated > 0 {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let value = try encoder.encode(credentials)
            guard value.count <= maximumVaultBytes else { throw BrowserPasswordStoreError.fileTooLarge }
            try Task.checkCancellation()
            try await backend.save(value)
        }
        return .init(imported: imported, updated: updated, skipped: parsed.skipped, duplicates: duplicates, total: credentials.count)
    }

    private func loadVault() async throws -> [BrowserPasswordCredential] {
        guard let data = try await backend.load() else { return [] }
        guard data.count <= maximumVaultBytes,
              let credentials = try? PropertyListDecoder().decode([BrowserPasswordCredential].self, from: data),
              Set(credentials.map(\.id)).count == credentials.count,
              credentials.allSatisfy({ PasswordOrigin(url: $0.url) == $0.origin && !$0.password.isEmpty }) else {
            throw BrowserPasswordStoreError.corruptVault
        }
        return credentials
    }

    private func acquireImport() async {
        if !importing { importing = true; return }
        await withCheckedContinuation { importWaiters.append($0) }
    }

    private func releaseImport() {
        if importWaiters.isEmpty { importing = false }
        else { importWaiters.removeFirst().resume() }
    }
}
