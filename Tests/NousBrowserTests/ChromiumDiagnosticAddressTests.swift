import Foundation
import Testing
@testable import NousBrowser

@Suite("Chromium diagnostic address entry")
struct ChromiumDiagnosticAddressTests {
    @Test func onlyExplicitDiagnosticAddressesAreRecognized() {
        for address in ["chrome://version", "chrome://gpu/", "chrome://discards"] {
            #expect(BrowserModel.normalizeAddress(address)?.absoluteString == address)
            #expect(BrowserAddressPrimarySuggestion.navigationURL(for: address)?.absoluteString == address)
            #expect(!BrowserModel.canOpenExternalURL(URL(string: address)!))
        }
        for address in ["chrome://crash", "chrome://quit", "chrome://discards@evil.test", "chrome://user:secret@discards",
                        "chrome://discards:123", "chrome://discards/extra", "chrome://discards?open=1", "javascript:alert(1)"] {
            #expect(BrowserModel.normalizeAddress(address) == nil)
            #expect(BrowserAddressPrimarySuggestion.navigationURL(for: address) == nil)
        }
    }

    @Test func diagnosticPrimarySuggestionMatchesSubmissionAfterTrimming() {
        for address in ["  chrome://version  ", "\nCHROME://GPU/\t", "chrome://DISCARDS"] {
            let destination = BrowserModel.normalizeAddress(address)
            #expect(destination != nil)
            #expect(BrowserAddressPrimarySuggestion.navigationURL(for: address) == destination)
        }
    }
}
