import Foundation
import Testing
@testable import NousBrowser

@Suite("Address host punctuation and width")
struct BrowserAddressInputTests {
    @Test func bareDomainsAcceptTheThreeCommonNonASCIIStopsAndHostWidth() {
        for address in ["x。com", "x．com", "x｡com", "ｘ。ｃｏｍ", "ｘ．com", "x｡ｃｏｍ"] {
            #expect(BrowserAddressInput.websiteURL(for: address)?.absoluteString == "https://x.com")
            #expect(BrowserModel.normalizeAddress(address)?.absoluteString == "https://x.com")
        }
    }

    @Test func explicitWebSchemesAndHostWidthAreNormalizedWithoutChangingTheSuffix() throws {
        let suffix = "/ｆｕｌｌ。ｗｉｄｔｈ/中文?q=ｘ。ｃｏｍ＋测试&url=https://raw。example/a#片段。ｚ"
        for prefix in ["https://", "HTTPS://", "ｈｔｔｐｓ://"] {
            let actual = try #require(BrowserAddressInput.websiteURL(for: prefix + "ｘ。ｃｏｍ" + suffix))
            let expected = try #require(URL(string: "https://x.com" + suffix))
            #expect(actual.absoluteString == expected.absoluteString)
        }
        #expect(BrowserAddressInput.websiteURL(for: "http://x．com/path")?.absoluteString == "http://x.com/path")
    }

    @Test func anEmbeddedURLInABareAddressesQueryDoesNotBecomeTheOuterScheme() throws {
        let suffix = "/path?target=https://unchanged。com/a&q=ａｂｃ#frag｡"
        let actual = try #require(BrowserAddressInput.websiteURL(for: "x。com" + suffix))
        #expect(actual.absoluteString == URL(string: "https://x.com" + suffix)?.absoluteString)
    }

    @Test func ordinaryPunctuationAndSearchOperatorsRemainVerbatimForEveryEngine() {
        let queries = ["你好。世界", "你好．世界", "你好｡世界", "这是一个中文句子。", "一个中文句子，包含标点。",
                       "想了解 x。com 的资料", "site:example.com", "site:example.com 中文。资料", "搜索：ａｂｃ。"]
        for query in queries {
            #expect(BrowserAddressInput.websiteURL(for: query) == nil)
            for engine in BrowserSearchEngine.allCases {
                #expect(BrowserModel.normalizeAddress(query, searchEngine: engine) == engine.searchURL(query: query))
            }
        }
    }

    @Test func supportedIDNsWithAnASCIITopLevelDomainRemainAddresses() throws {
        let expected = try #require(URL(string: "https://例子.com"))
        for address in ["例子。com", "例子．com", "例子｡com", "例子.com"] {
            #expect(BrowserAddressInput.websiteURL(for: address)?.host == expected.host)
        }
        let explicit = try #require(BrowserAddressInput.websiteURL(for: "https://例子。中国/path"))
        #expect(explicit == URL(string: "https://例子.中国/path"))
    }

    @Test func localAddressesPortsAndExistingHTTPSKeepTheirBehavior() {
        let cases = [
            ("localhost", "http://localhost"),
            ("localhost:8080/test", "http://localhost:8080/test"),
            ("127.0.0.1:4000", "http://127.0.0.1:4000"),
            ("[::1]:8765/path", "http://[::1]:8765/path"),
            ("192.168.1.5:8443/path", "https://192.168.1.5:8443/path"),
            ("[2001:db8::1]:8443/path", "https://[2001:db8::1]:8443/path"),
            ("https://localhost:8080/test", "https://localhost:8080/test"),
            (" https://example.com/path?q=1 ", "https://example.com/path?q=1")
        ]
        for (input, expected) in cases {
            #expect(BrowserAddressInput.websiteURL(for: input)?.absoluteString == expected)
            #expect(BrowserModel.normalizeAddress(input)?.absoluteString == expected)
        }
    }

    @Test func unsafeSchemesAndInvalidExplicitURLsCannotBecomeFoldedHostAddresses() {
        for input in ["javascript:alert('x。com')", "javascript:443@x。com", "data:text/html,x。com",
                      "file:///tmp/x。html", "ftp://x。com", "custom://x。com", "https://", "http://?q=x"] {
            #expect(BrowserAddressInput.websiteURL(for: input) == nil)
            #expect(BrowserModel.normalizeAddress(input) == nil)
        }
        #expect(BrowserModel.normalizeAddress(" \n\t ") == nil)
    }

    @Test func explicitUserInfoIsNotWidthOrPunctuationFoldedWithTheHost() throws {
        let suffix = "/Path。Test?q=Ｘ#piece｡"
        let input = "https://synthetic。user:ｆａｋｅ@ｘ。ｃｏｍ" + suffix
        let actual = try #require(BrowserAddressInput.websiteURL(for: input))
        let expected = try #require(URL(string: "https://synthetic。user:ｆａｋｅ@x.com" + suffix))
        #expect(actual.absoluteString == expected.absoluteString)
    }
}
