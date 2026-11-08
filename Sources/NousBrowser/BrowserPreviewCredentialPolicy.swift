import Foundation
import Security

/// An injectable process-policy scope. No key retrieval, unlocking, ACL change,
/// or trust-store change is involved. Failed setup must abort preview startup.
@MainActor
final class BrowserCredentialUISuppression {
    private let getAllowed: () -> (OSStatus, Bool)
    private let setAllowed: (Bool) -> OSStatus
    private var previousAllowed: Bool?

    init(getAllowed: @escaping () -> (OSStatus, Bool), setAllowed: @escaping (Bool) -> OSStatus) {
        self.getAllowed = getAllowed
        self.setAllowed = setAllowed
    }

    func start(required: Bool) throws {
        guard required, previousAllowed == nil else { return }
        let (status, previous) = getAllowed()
        guard status == errSecSuccess else { throw BrowserPasswordStoreError.keychain(status) }
        let result = setAllowed(false)
        guard result == errSecSuccess else { throw BrowserPasswordStoreError.keychain(result) }
        previousAllowed = previous
    }

    @discardableResult
    func finish() -> OSStatus {
        guard let previousAllowed else { return errSecSuccess }
        let status = setAllowed(previousAllowed)
        if status == errSecSuccess { self.previousAllowed = nil }
        return status
    }
}

@MainActor
enum BrowserPreviewCredentialPolicy {
    private static let suppression = BrowserCredentialUISuppression(getAllowed: {
        var allowed: DarwinBoolean = false
        let status = SecKeychainGetUserInteractionAllowed(&allowed)
        return (status, allowed.boolValue)
    }, setAllowed: { SecKeychainSetUserInteractionAllowed($0) })

    /// Reject incomplete/mixed metadata before any credential API is called.
    nonisolated static func validateConfiguration(bundleIdentifier: String?, distributionChannel: String?,
                                                   storagePolicy: String?) throws {
        guard BrowserPasswordVaultScope.distribution(bundleIdentifier: bundleIdentifier,
            distributionChannel: distributionChannel, storagePolicy: storagePolicy) != nil else {
            throw BrowserPasswordStoreError.keychain(errSecCSInternalError)
        }
    }

    /// This outer scope starts before any app credential store initializes.
    /// The native CEF guard nests inside it and restores false after CefShutdown.
    static func startIfNeeded() throws {
        try validateConfiguration(bundleIdentifier: Bundle.main.bundleIdentifier,
            distributionChannel: Bundle.main.object(forInfoDictionaryKey: "NousDistributionChannel") as? String,
            storagePolicy: Bundle.main.object(forInfoDictionaryKey: "NousCredentialStorage") as? String)
        try suppression.start(required: true)
    }

    /// Restore the caller's prior policy on normal termination and startup error.
    @discardableResult
    static func finish() -> OSStatus { suppression.finish() }
}
