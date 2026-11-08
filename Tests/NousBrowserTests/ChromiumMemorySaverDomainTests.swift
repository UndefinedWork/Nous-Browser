import Testing
@testable import NousBrowser

@Suite("Chromium Memory Saver domain input")
struct ChromiumMemorySaverDomainTests {
    @Test func canonicalDomainsAndInternationalNames() {
        #expect(ChromiumMemorySaverDomain.normalized("  EXAMPLE.com.\n") == "example.com")
        #expect(ChromiumMemorySaverDomain.normalized("slides.zoom.com") == "slides.zoom.com")
        #expect(ChromiumMemorySaverDomain.normalized("例子.测试") == "xn--fsqu00a.xn--0zwm56d")
        #expect(ChromiumMemorySaverDomain.normalized("localhost") == "localhost")
        #expect(ChromiumMemorySaverDomain.normalized("127.0.0.1") == "127.0.0.1")
    }

    @Test(arguments: ["", " ", ".example.com", "*.example.com", "[*.]example.com",
        "https://example.com", "example.com/a", "example.com?x=1", "example.com#x",
        "example.com:443", "user@example.com", "example.com\\other", "exa mple.com",
        "example..com", "example.com..", "-example.com", "example-.com", "foo_bar.com",
        "example\u{0000}.com", "exam\nple.com", "%65xample.com", "[::1]",
        "127.1", "2130706433", "0x7f000001", "0177.0.0.1", "256.0.0.1"])
    func rejectsAmbiguousInput(_ input: String) {
        #expect(ChromiumMemorySaverDomain.normalized(input) == nil)
    }

    @Test func enforcesDNSLengthBounds() {
        #expect(ChromiumMemorySaverDomain.normalized(String(repeating: "a", count: 63) + ".com") != nil)
        #expect(ChromiumMemorySaverDomain.normalized(String(repeating: "a", count: 64) + ".com") == nil)
        #expect(ChromiumMemorySaverDomain.normalized(Array(repeating: String(repeating: "a", count: 63), count: 4).joined(separator: ".")) == nil)
    }
}
