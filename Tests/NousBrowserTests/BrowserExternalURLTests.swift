import Foundation
import Testing
@testable import NousBrowser

@Suite("External website and HTML document opening")
struct BrowserExternalURLTests {
    @Test func acceptsWebsitesAndSupportedLocalHTMLDocuments() throws {
        #expect(BrowserModel.canOpenExternalURL(try #require(URL(string: "https://example.com/path?q=hello"))))
        #expect(BrowserModel.canOpenExternalURL(try #require(URL(string: "http://localhost:8080/"))))
        for filename in ["page.html", "page.htm", "page.xhtml", "PAGE.HTML", "saved page.HTM"] {
            #expect(BrowserModel.canOpenExternalURL(URL(fileURLWithPath: "/tmp/" + filename)))
        }
    }

    @Test func rejectsUnsupportedFilesDirectoriesAndApplicationSchemes() throws {
        for address in ["mailto:person@example.com", "ftp://example.com/page.html", "javascript:alert(1)", "data:text/html,test", "https:relative-page.html"] {
            #expect(!BrowserModel.canOpenExternalURL(try #require(URL(string: address))))
        }
        for filename in ["notes.txt", "image.png", "document.pdf", "archive.html.zip"] {
            #expect(!BrowserModel.canOpenExternalURL(URL(fileURLWithPath: "/tmp/" + filename)))
        }
        #expect(!BrowserModel.canOpenExternalURL(URL(fileURLWithPath: "/tmp/archive.html", isDirectory: true)))
        #expect(BrowserModel.normalizeAddress("file:///tmp/page.html") == nil)
    }
}
