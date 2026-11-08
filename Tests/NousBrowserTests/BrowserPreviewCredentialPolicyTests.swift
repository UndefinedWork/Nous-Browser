import Security
import Testing
@testable import NousBrowser

@Suite("Isolated-build credential UI policy", .serialized)
@MainActor
struct BrowserPreviewCredentialPolicyTests {
    @Test func validOptInIsRequiredBeforeEitherDistributionStarts() throws {
        try BrowserPreviewCredentialPolicy.validateConfiguration(bundleIdentifier: "com.cellier.nous-browser",
            distributionChannel: "github", storagePolicy: "local-key")
        try BrowserPreviewCredentialPolicy.validateConfiguration(bundleIdentifier: "com.cellier.nous-browser.chromium-preview",
            distributionChannel: "chromium-preview", storagePolicy: "local-key")
        for policy in [nil, "legacy", ""] as [String?] {
            #expect(throws: BrowserPasswordStoreError.self) {
                try BrowserPreviewCredentialPolicy.validateConfiguration(bundleIdentifier: "com.cellier.nous-browser",
                    distributionChannel: "github", storagePolicy: policy)
            }
        }
        #expect(throws: BrowserPasswordStoreError.self) {
            try BrowserPreviewCredentialPolicy.validateConfiguration(bundleIdentifier: "com.cellier.nous-browser",
                distributionChannel: "chromium-preview", storagePolicy: "local-key")
        }
    }

    @Test func nestedNativeScopeDoesNotReenableUIBeforeOuterHostScopeFinishes() throws {
        let api = FakePolicy(initial: true)
        let host = api.scope(), native = api.scope()
        try host.start(required: true)
        try native.start(required: true)
        #expect(!api.allowed)
        #expect(native.finish() == errSecSuccess && !api.allowed)
        #expect(host.finish() == errSecSuccess && api.allowed)
        #expect(api.writes == [false, false, false, true])
    }

    @Test(arguments: [false, true])
    func restoresExactlyThePriorProcessPolicy(initial: Bool) throws {
        let api = FakePolicy(initial: initial)
        let scope = api.scope()
        try scope.start(required: true)
        try scope.start(required: true)
        #expect(api.getCalls == 1 && api.writes == [false] && !api.allowed)
        #expect(scope.finish() == errSecSuccess)
        #expect(scope.finish() == errSecSuccess)
        #expect(api.allowed == initial && api.writes == [false, initial])
    }

    @Test func irrelevantHostNeverCallsTheSystemPolicyAPI() throws {
        let api = FakePolicy(initial: true)
        let scope = api.scope()
        try scope.start(required: false)
        #expect(scope.finish() == errSecSuccess)
        #expect(api.getCalls == 0 && api.writes.isEmpty && api.allowed)
    }

    @Test func failedSetupDoesNotClaimAValidSuppressionScope() {
        let getFailure = FakePolicy(initial: true)
        getFailure.getStatus = errSecInteractionNotAllowed
        let first = getFailure.scope()
        #expect(throws: BrowserPasswordStoreError.self) { try first.start(required: true) }
        #expect(first.finish() == errSecSuccess && getFailure.writes.isEmpty)

        let setFailure = FakePolicy(initial: true)
        setFailure.setStatus = errSecParam
        let second = setFailure.scope()
        #expect(throws: BrowserPasswordStoreError.self) { try second.start(required: true) }
        #expect(second.finish() == errSecSuccess)
        #expect(setFailure.writes == [false] && setFailure.allowed)
    }

    @Test func failedRestoreRetainsOwnershipForAnExplicitRetry() throws {
        let api = FakePolicy(initial: true)
        let scope = api.scope()
        try scope.start(required: true)
        api.setStatus = errSecParam
        #expect(scope.finish() == errSecParam && !api.allowed)
        api.setStatus = errSecSuccess
        #expect(scope.finish() == errSecSuccess && api.allowed)
        #expect(api.writes == [false, true, true])
    }

    @MainActor
    private final class FakePolicy {
        var allowed: Bool
        var getStatus: OSStatus = errSecSuccess
        var setStatus: OSStatus = errSecSuccess
        var getCalls = 0
        var writes: [Bool] = []
        init(initial: Bool) { allowed = initial }
        func scope() -> BrowserCredentialUISuppression {
            BrowserCredentialUISuppression(getAllowed: {
                self.getCalls += 1
                return (self.getStatus, self.allowed)
            }, setAllowed: {
                self.writes.append($0)
                if self.setStatus == errSecSuccess { self.allowed = $0 }
                return self.setStatus
            })
        }
    }
}
