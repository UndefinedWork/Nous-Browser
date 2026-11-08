import CryptoKit
import Foundation
import Testing
@testable import NousBrowser

struct BrowserPasswordVaultStorageTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nous-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func localSecretIsCreatedOnceAndPrivate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try NousLocalSecret.load(in: directory)
        #expect(first.count == 32)
        #expect(try NousLocalSecret.load(in: directory) == first)
        let mode = try FileManager.default.attributesOfItem(atPath: NousLocalSecret.url(in: directory).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(NousLocalSecret.chromiumPassword(first) == NousLocalSecret.chromiumPassword(first))
    }

    @Test func fileVaultSurvivesANewBackendAndRejectsAnotherKey() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = try NousLocalSecret.load(in: directory)
        let url = BrowserPasswordVaultScope.fileURL(in: directory)
        let key = NousLocalSecret.derive(secret, purpose: "password-vault")
        try await BrowserPasswordFileBackend(url: url, key: key).save(Data("vault".utf8))
        // A later build constructs a fresh backend from the same secret.
        #expect(try await BrowserPasswordFileBackend(url: url, key: key).load() == Data("vault".utf8))
        #expect(try Data(contentsOf: url) != Data("vault".utf8))
        await #expect(throws: BrowserPasswordStoreError.self) {
            try await BrowserPasswordFileBackend(url: url, key: SymmetricKey(size: .bits256)).load()
        }
    }

    @Test func onlyConfiguredDistributionsOpenAVault() {
        #expect(BrowserPasswordVaultScope.distribution(bundleIdentifier: "com.cellier.nous-browser",
            distributionChannel: "github", storagePolicy: "local-key") == .github)
        for policy: String? in [nil, "", "isolated-build"] {
            #expect(BrowserPasswordVaultScope.distribution(bundleIdentifier: "com.cellier.nous-browser",
                distributionChannel: "github", storagePolicy: policy) == nil)
        }
        #expect(BrowserPasswordVaultScope.distribution(bundleIdentifier: "com.example",
            distributionChannel: "github", storagePolicy: "local-key") == nil)
    }
}
