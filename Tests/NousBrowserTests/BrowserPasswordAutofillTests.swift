import AppKit
import Foundation
import Testing
@testable import NousBrowser

/// Native credential gates that run without starting CEF, reading a password
/// store, or creating an authenticated page. Real form behavior is exercised by
/// ChromiumSmokeCheck's isolated app-hosted credential fixtures.
@Suite("Password autofill native boundaries", .serialized)
@MainActor
struct BrowserPasswordAutofillTests {
    @Test func originsAreExactHTTPSOrigins() throws {
        let first = try #require(BrowserPasswordAutofill.Origin(url: URL(string: "https://example.test/login")!))
        #expect(first == BrowserPasswordAutofill.Origin(url: URL(string: "https://example.test:443/other")!))
        #expect(first != BrowserPasswordAutofill.Origin(url: URL(string: "https://example.test:444/login")!))
        #expect(first != BrowserPasswordAutofill.Origin(url: URL(string: "https://sub.example.test/login")!))
        #expect(BrowserPasswordAutofill.Origin(url: URL(string: "http://example.test/login")!) == nil)
        #expect(BrowserPasswordAutofill.Origin(url: URL(string: "https://user:secret@example.test/login")!) == nil)
        #expect(first.url.absoluteString == "https://example.test")
    }

    @Test func loopbackOptInNeverAllowsRemoteHTTPAndPreservesIPv6Authority() throws {
        #expect(BrowserPasswordAutofill.Origin(url: URL(string: "http://example.test/login")!,
            allowLoopbackHTTPForTesting: true) == nil)
        let local = try #require(BrowserPasswordAutofill.Origin(url: URL(string: "http://[::1]:8879/login")!,
            allowLoopbackHTTPForTesting: true))
        #expect(local.serialized == "http://[::1]:8879")
        #expect(BrowserPasswordAutofill.Origin(url: URL(string: "http://localhost/login")!) == nil)
        #expect(!BrowserPasswordAutofill.testingHTTPAllowed(false))
        #if !DEBUG
        #expect(!BrowserPasswordAutofill.testingHTTPAllowed(true))
        #endif
    }

    @Test func malformedValuesAreRejectedBeforeAnyPageOperation() async throws {
        let view = ChromiumPageView(frame: .zero)
        defer { view.shutdown() }
        let origin = try #require(BrowserPasswordAutofill.Origin(url: URL(string: "https://example.test")!))
        let values: [BrowserPasswordAutofill.Values] = [
            .init(username: "synthetic", password: ""),
            .init(username: "synthetic", password: "line\nbreak"),
            .init(username: "synthetic", password: "line\rbreak"),
            .init(username: "synthetic", password: String(repeating: "x", count: 65_537)),
            .init(username: String(repeating: "x", count: 16_385), password: "synthetic-only")
        ]
        for value in values {
            do {
                _ = try await BrowserPasswordAutofill.fill(value, in: view, expectedOrigin: origin,
                    token: UUID().uuidString)
                Issue.record("Malformed credential reached the page bridge")
            } catch BrowserPasswordAutofill.Failure.invalidCredential {}
        }
        #expect(view.url == nil)
    }

    @Test func missingDocumentAndInvalidTokenCannotDispatchCredentialValues() async throws {
        let view = ChromiumPageView(frame: .zero)
        defer { view.shutdown() }
        let origin = try #require(BrowserPasswordAutofill.Origin(url: URL(string: "https://example.test")!))
        for token in ["invalid-token", UUID().uuidString] {
            do {
                _ = try await BrowserPasswordAutofill.fill(.init(username: "synthetic", password: "synthetic-only"),
                    in: view, expectedOrigin: origin, token: token)
                Issue.record("A missing document or invalid token was accepted")
            } catch BrowserPasswordAutofill.Failure.staleDocument {}
        }
    }

    @Test func cancellationWinsBeforeCredentialValidationOrPageWork() async throws {
        let view = ChromiumPageView(frame: .zero)
        defer { view.shutdown() }
        let origin = try #require(BrowserPasswordAutofill.Origin(url: URL(string: "https://example.test")!))
        let operation = Task { @MainActor in
            _ = try await BrowserPasswordAutofill.fill(.init(username: "synthetic", password: ""),
                in: view, expectedOrigin: origin, token: "invalid")
        }
        operation.cancel()
        do {
            try await operation.value
            Issue.record("A canceled operation was accepted")
        } catch is CancellationError {}
    }
}
