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

    @Test func signingAnUpdateKeepsTheExistingLocalChromiumProfileAndKey() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = BrowserRuntimePaths(distribution: .production, applicationSupport: root, home: root)
        let previous = try ChromiumStorageIdentity.resolve(paths: paths, teamSigned: false)
        try FileManager.default.createDirectory(at: previous.profile, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: previous.profile.appendingPathComponent("Local State"))
        let upgraded = try ChromiumStorageIdentity.resolve(paths: paths, teamSigned: true)
        #expect(upgraded.profile == previous.profile)
        #expect(upgraded.safeStoragePassword == previous.safeStoragePassword)
        #expect(!FileManager.default.fileExists(atPath: paths.teamChromiumProfile.path))

        let key = NousLocalSecret.url(in: paths.directory)
        try FileManager.default.removeItem(at: key)
        #expect(throws: CocoaError.self) { try ChromiumStorageIdentity.resolve(paths: paths, teamSigned: true) }
        #expect(!FileManager.default.fileExists(atPath: key.path))
        let corrupt = Data([1])
        try corrupt.write(to: key)
        #expect(throws: CocoaError.self) { try ChromiumStorageIdentity.resolve(paths: paths, teamSigned: true) }
        #expect(try Data(contentsOf: key) == corrupt)
    }

    @Test func initializedTeamProfileSurvivesAnEmptyLocalDirectoryAndKeepsVaultChoiceIndependent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = BrowserRuntimePaths(distribution: .production, applicationSupport: root, home: root)
        for directory in [paths.localChromiumProfile, paths.teamChromiumProfile] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("Default"), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: paths.teamChromiumProfile.appendingPathComponent("Default/Preferences"))
        let storage = try ChromiumStorageIdentity.resolve(paths: paths, teamSigned: true)
        #expect(storage.profile == paths.teamChromiumProfile)
        #expect(storage.safeStoragePassword == nil)
        #expect(try BrowserPasswordVaultScope.usesTeamVault(in: paths.directory) { Issue.record("Unexpected keychain query"); return false })

        try Data("existing vault".utf8).write(to: BrowserPasswordVaultScope.fileURL(in: paths.directory))
        #expect(try !BrowserPasswordVaultScope.usesTeamVault(in: paths.directory) { false })
        #expect(try BrowserPasswordVaultScope.usesTeamVault(in: paths.directory) { true })
        #expect(throws: CocoaError.self) { try paths.localStorageSecret() }
        #expect(!FileManager.default.fileExists(atPath: NousLocalSecret.url(in: paths.directory).path))
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
