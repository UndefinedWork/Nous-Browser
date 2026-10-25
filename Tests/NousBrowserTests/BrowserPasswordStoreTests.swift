import Foundation
import LocalAuthentication
import Testing
@testable import NousBrowser

@Suite("Password CSV and origins")
struct BrowserPasswordCSVTests {
    @Test func appleCSVPreservesCredentialBytesAndIgnoresNotesAndOTP() throws {
        let csv = "\u{FEFF}Title,URL,Username,Password,Notes,OTPAuth\r\n\"Example, Inc\",https://EXAMPLE.com:443/login,\" 用户 name \",\"p,a\"\"ss\r\nword \",private note,otpauth://totp/secret\r\n"
        let parsed = try BrowserPasswordCSV.parse(Data(csv.utf8))
        let credential = try #require(parsed.credentials.first)
        #expect(parsed.credentials.count == 1)
        #expect(credential.title == "Example, Inc")
        #expect(credential.username == " 用户 name ")
        #expect(Array(credential.password.utf8) == Array("p,a\"ss\r\nword ".utf8))
        #expect(credential.origin.description == "https://example.com")
        #expect(credential.notes.isEmpty && credential.otpAuth.isEmpty)
    }

    @Test func chromeCSVSkipsInvalidRowsAndDeduplicatesByExactOriginAndUsername() throws {
        let csv = "name,url,username,password,note\nFirst,https://example.com/a,user,old,n\nLast,https://example.com/b,user,new,n\nHTTP,http://example.com,user,other,n\nSub,https://sub.example.com,user,sub,n\nInvalid,javascript:alert(1),user,password,n\nEmpty,https://example.com,empty,,n\n"
        let parsed = try BrowserPasswordCSV.parse(Data(csv.utf8))
        #expect(parsed.credentials.count == 3)
        #expect(parsed.credentials[0].title == "Last")
        #expect(parsed.credentials[0].password == "new")
        #expect(parsed.duplicates == 1 && parsed.skipped == 2)
    }

    @Test func exactOriginNormalizationDoesNotExpandTrust() {
        #expect(PasswordOrigin(string: "https://EXAMPLE.com:443/a?q=1#x") == PasswordOrigin(string: "https://example.com"))
        #expect(PasswordOrigin(string: "http://example.com:80/") == PasswordOrigin(string: "http://example.com"))
        #expect(PasswordOrigin(string: "https://example.com") != PasswordOrigin(string: "http://example.com"))
        #expect(PasswordOrigin(string: "https://example.com") != PasswordOrigin(string: "https://sub.example.com"))
        #expect(PasswordOrigin(string: "https://example.com:8443") != PasswordOrigin(string: "https://example.com"))
        for value in ["file:///tmp/login.html", "https:example.com", "https://user:pass@example.com", "https://exa mple.com", "https://example.com\\@evil.test", "https://example.com:99999", " https://example.com"] {
            #expect(PasswordOrigin(string: value) == nil)
        }
    }

    @Test func malformedCSVDoesNotPartiallyImport() throws {
        #expect(throws: BrowserPasswordStoreError.self) { try BrowserPasswordCSV.parse(Data("url,username,password\nhttps://example.com,user,\"unterminated".utf8)) }
        #expect(throws: BrowserPasswordStoreError.self) { try BrowserPasswordCSV.parse(Data("url,url,username,password\na,b,c,d".utf8)) }
        #expect(throws: BrowserPasswordStoreError.self) { try BrowserPasswordCSV.parse(Data("name,secret\nx,y".utf8)) }
    }

    @Test func nonemptyRowLimitBoundsInvalidAndDuplicateRecordsDuringParsing() throws {
        let header = "url,username,password\n"
        let row = "https://example.com,user,synthetic\n"
        let maximum = header + String(repeating: row, count: BrowserPasswordCSV.maximumRecords)
        let parsed = try BrowserPasswordCSV.parse(Data(maximum.utf8))
        #expect(parsed.credentials.count == 1)
        #expect(parsed.duplicates == BrowserPasswordCSV.maximumRecords - 1)
        #expect(throws: BrowserPasswordStoreError.fileTooLarge) {
            try BrowserPasswordCSV.parse(Data((maximum + row).utf8))
        }
        let invalid = header + String(repeating: "javascript:bad,user,p\n", count: BrowserPasswordCSV.maximumRecords + 1)
        #expect(throws: BrowserPasswordStoreError.fileTooLarge) { try BrowserPasswordCSV.parse(Data(invalid.utf8)) }
    }
}

private actor FixturePasswordBackend: BrowserPasswordVaultBackend {
    var data: Data?
    var reads = 0
    var writes = 0
    var failSave = false
    func load() -> Data? { reads += 1; return data }
    func save(_ value: Data) throws {
        if failSave { throw BrowserPasswordStoreError.keychain(-1) }
        data = value
        writes += 1
    }
    func setFailSave(_ value: Bool) { failSave = value }
    func snapshot() -> (Data?, Int, Int) { (data, reads, writes) }
}

@MainActor private final class FixturePasswordAuthentication: BrowserPasswordAuthenticating {
    var calls = 0
    var error: Error?
    var cancelCurrentTask = false
    func authenticate(reason: String) async throws {
        calls += 1
        if let error { throw error }
        if cancelCurrentTask { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

@Suite("Authenticated password vault", .serialized)
struct BrowserPasswordStoreTests {
    private func csv(_ username: String, _ password: String, host: String = "https://example.com") -> Data {
        Data("name,url,username,password,note\nExample,\(host),\(username),\(password),ignored\n".utf8)
    }

    @Test @MainActor func importingAndReadingAlwaysAuthenticateAndMatchExactOrigin() async throws {
        let backend = FixturePasswordBackend()
        let auth = FixturePasswordAuthentication()
        let store = BrowserPasswordStore(backend: backend, authentication: auth)
        let result = try await store.importCSV(csv("alice", "fixture-password"), reason: "Fixture")
        #expect(result.imported == 1 && result.total == 1)
        let origin = try #require(PasswordOrigin(string: "https://example.com/login"))
        let credentials = try await store.credentials(for: origin, reason: "Fixture")
        #expect(credentials.count == 1 && credentials[0].username == "alice")
        let sub = try #require(PasswordOrigin(string: "https://sub.example.com"))
        #expect(try await store.credentials(for: sub, reason: "Fixture").isEmpty)
        #expect(auth.calls == 3)
        let state = await backend.snapshot()
        #expect(state.0?.starts(with: Data("bplist00".utf8)) == true)
    }

    @Test @MainActor func canceledDeviceVerificationDoesNotReadOrWriteAndKeepsLAError() async throws {
        let backend = FixturePasswordBackend()
        let auth = FixturePasswordAuthentication()
        auth.error = LAError(.userCancel)
        let store = BrowserPasswordStore(backend: backend, authentication: auth)
        do { _ = try await store.importCSV(csv("alice", "synthetic"), reason: "Fixture"); Issue.record("Expected cancellation") }
        catch let error as LAError { #expect(error.code == .userCancel) }
        let state = await backend.snapshot()
        #expect(state.1 == 0 && state.2 == 0)
    }

    @Test @MainActor func cancellationAfterVerificationCannotReuseAuthorization() async throws {
        let backend = FixturePasswordBackend()
        let auth = FixturePasswordAuthentication()
        auth.cancelCurrentTask = true
        let store = BrowserPasswordStore(backend: backend, authentication: auth)
        let task = Task { try await store.importCSV(csv("alice", "synthetic"), reason: "Fixture") }
        do { _ = try await task.value; Issue.record("Expected task cancellation") }
        catch is CancellationError {}
        let state = await backend.snapshot()
        #expect(state.1 == 0 && state.2 == 0)
    }

    @Test @MainActor func duplicateImportsUpdateAtomicallyAndFailedSaveKeepsOldData() async throws {
        let backend = FixturePasswordBackend()
        let auth = FixturePasswordAuthentication()
        let store = BrowserPasswordStore(backend: backend, authentication: auth)
        _ = try await store.importCSV(csv("alice", "first"), reason: "Fixture")
        let duplicate = try await store.importCSV(csv("alice", "first"), reason: "Fixture")
        #expect(duplicate.duplicates == 1 && duplicate.updated == 0)
        let updated = try await store.importCSV(csv("alice", "second"), reason: "Fixture")
        #expect(updated.updated == 1 && updated.total == 1)
        let before = await backend.snapshot()
        await backend.setFailSave(true)
        do { _ = try await store.importCSV(csv("bob", "third"), reason: "Fixture"); Issue.record("Expected save failure") }
        catch is BrowserPasswordStoreError {}
        let after = await backend.snapshot()
        #expect(after.0 == before.0 && after.2 == before.2)
    }

    @Test @MainActor func concurrentImportsAreSerializedWithoutLosingAccounts() async throws {
        let backend = FixturePasswordBackend()
        let auth = FixturePasswordAuthentication()
        let store = BrowserPasswordStore(backend: backend, authentication: auth)
        async let first = store.importCSV(csv("alice", "one"), reason: "Fixture")
        async let second = store.importCSV(csv("bob", "two"), reason: "Fixture")
        _ = try await (first, second)
        let credentials = try await store.credentials(for: #require(PasswordOrigin(string: "https://example.com")), reason: "Fixture")
        #expect(Set(credentials.map(\.username)) == ["alice", "bob"])
        #expect(auth.calls == 3)
    }

    @Test @MainActor func oversizedReplacementIsRejectedBeforeWritingAndKeepsExistingVault() async throws {
        let backend = FixturePasswordBackend()
        let auth = FixturePasswordAuthentication()
        let store = BrowserPasswordStore(backend: backend, authentication: auth, maximumVaultBytes: 1_024)
        _ = try await store.importCSV(csv("alice", "small"), reason: "Fixture")
        let before = await backend.snapshot()
        do {
            _ = try await store.importCSV(csv("bob", String(repeating: "x", count: 2_048)), reason: "Fixture")
            Issue.record("Expected vault size limit")
        } catch let error as BrowserPasswordStoreError { #expect(error == .fileTooLarge) }
        let after = await backend.snapshot()
        #expect(after.0 == before.0 && after.2 == before.2)
    }
}
