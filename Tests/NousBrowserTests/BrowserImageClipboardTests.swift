import AppKit
import Testing
import WebKit
@testable import NousBrowser

@Suite("Copy Image fallback", .serialized)
@MainActor
struct BrowserImageClipboardTests {
    @Test func svgProducesStandardBitmapsWithTransparentPixels() throws {
        let image = try BrowserImageClipboard.encode(svg(width: 8, height: 6,
            content: "<rect x='2' y='1' width='4' height='3' fill='#ff0000'/>"))
        #expect(image.width == 8)
        #expect(image.height == 6)
        for data in [image.png, image.tiff] {
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(bitmap.pixelsWide == 8)
            #expect(bitmap.pixelsHigh == 6)
            #expect(try #require(bitmap.colorAt(x: 0, y: 0)).alphaComponent == 0)
            let red = try #require(bitmap.colorAt(x: 3, y: 2))
            #expect(red.alphaComponent > 0.99)
            #expect(red.redComponent > 0.99)
            #expect(red.greenComponent < 0.01)
        }
    }

    @Test func svgUsesItsOriginalDimensionsWithoutExpandingAllImageRepresentations() throws {
        let image = try BrowserImageClipboard.encode(svg(width: 1300, height: 1300,
            content: "<circle cx='650' cy='650' r='500' fill='#d97757'/>"))
        #expect(image.width == 1300)
        #expect(image.height == 1300)
        // A direct NSImage.tiffRepresentation can expand SVG into many large
        // representations. This output contains only the bounded source size.
        #expect(image.tiff.count < 1_000_000)
        let bitmap = try #require(NSBitmapImageRep(data: image.tiff))
        #expect(bitmap.pixelsWide == 1300)
        #expect(bitmap.pixelsHigh == 1300)
    }

    @Test func rasterUsesPixelsRatherThanItsDPIAdjustedPointSize() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        memset(try #require(bitmap.bitmapData), 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        bitmap.size = NSSize(width: 4, height: 3)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let image = try BrowserImageClipboard.encode(data)
        #expect(image.width == 8)
        #expect(image.height == 6)
    }

    @Test(arguments: [(8193, 1), (4001, 4000)])
    func invalidOrExcessiveDimensionsAreRejected(width: Int, height: Int) {
        #expect(throws: BrowserImageClipboard.Failure.self) {
            try BrowserImageClipboard.encode(svg(width: width, height: height))
        }
    }

    @Test(arguments: ["<html><body>not an image</body></html>", "not an image", "%PDF-1.4\n"])
    func nonImagesAreRejected(value: String) {
        #expect(throws: BrowserImageClipboard.Failure.invalidImage) {
            try BrowserImageClipboard.encode(Data(value.utf8))
        }
    }

    @Test func oversizedSourceIsRejectedBeforeDecoding() {
        #expect(throws: BrowserImageClipboard.Failure.tooLarge) {
            try BrowserImageClipboard.encode(Data(count: BrowserImageClipboard.maximumBytes + 1))
        }
    }

    @Test func responseValidationRequiresAnImageOrBinaryPayloadAndBoundedSuccessfulResponse() throws {
        let url = URL(string: "https://example.test/image")!
        for mime in ["image/svg+xml", "image/png", "application/octet-stream"] {
            try BrowserImageClipboard.validateResponse(URLResponse(url: url, mimeType: mime,
                expectedContentLength: -1, textEncodingName: nil))
        }
        #expect(throws: BrowserImageClipboard.Failure.unsupportedResponse) {
            try BrowserImageClipboard.validateResponse(URLResponse(url: url, mimeType: "text/html",
                expectedContentLength: 10, textEncodingName: nil))
        }
        #expect(throws: BrowserImageClipboard.Failure.tooLarge) {
            try BrowserImageClipboard.validateResponse(URLResponse(url: url, mimeType: "image/png",
                expectedContentLength: BrowserImageClipboard.maximumBytes + 1, textEncodingName: nil))
        }
        #expect(throws: BrowserImageClipboard.Failure.unsupportedResponse) {
            try BrowserImageClipboard.validateResponse(HTTPURLResponse(url: url, statusCode: 404,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!)
        }
    }

    @Test func acceptsOnlyWebImageSchemesWithoutEmbeddedCredentials() {
        for value in ["https://example.test/image.svg", "http://example.test/image.png",
                      "blob:https://example.test/id", "data:image/svg+xml;base64,PHN2Zy8+"] {
            #expect(BrowserImageClipboard.acceptsURL(URL(string: value)!))
        }
        for value in ["file:///tmp/image.svg", "javascript:alert(1)",
                      "https://user:password@example.test/image.svg"] {
            #expect(!BrowserImageClipboard.acceptsURL(URL(string: value)!))
        }
    }

    @Test func successfulCopyWritesPNGAndTIFFWithoutOldLinkOrHTMLData() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("older content", forType: .string)
        pasteboard.setString("<a href='https://example.test/'>old link</a>", forType: .html)
        let image = try BrowserImageClipboard.encode(svg(width: 8, height: 6))
        #expect(try BrowserImageClipboard.write(image, to: pasteboard,
            expectedChangeCount: pasteboard.changeCount))
        #expect(pasteboard.types?.contains(.png) == true)
        #expect(pasteboard.types?.contains(.tiff) == true)
        #expect(pasteboard.data(forType: .html) == nil)
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(pasteboard.data(forType: .png) == image.png)
        #expect(pasteboard.data(forType: .tiff) == image.tiff)
    }

    @Test func aLaterCopyOrInvalidatedContextCannotBeOverwritten() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("initial", forType: .string)
        let expected = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("a newer user copy", forType: .string)
        let image = try BrowserImageClipboard.encode(svg(width: 8, height: 6))
        #expect(try !BrowserImageClipboard.write(image, to: pasteboard, expectedChangeCount: expected))
        #expect(pasteboard.string(forType: .string) == "a newer user copy")
        #expect(try !BrowserImageClipboard.write(image, to: pasteboard,
            expectedChangeCount: pasteboard.changeCount, isValid: { false }))
        #expect(pasteboard.string(forType: .string) == "a newer user copy")
    }

    @Test func invalidRequestsAreRejectedWithoutChangingTheClipboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("keep this", forType: .string)
        let count = pasteboard.changeCount
        let coordinator = BrowserImageClipboard()
        let webView = WKWebView()
        var completed = false
        coordinator.copyImage(from: URL(fileURLWithPath: "/tmp/image.svg"), in: webView,
            pasteboard: pasteboard, expectedChangeCount: count) { result in
                if case .failure(let error) = result {
                    #expect(error as? BrowserImageClipboard.Failure == .invalidURL)
                } else { Issue.record("Expected an invalid URL failure") }
                completed = true
            }
        #expect(completed)
        #expect(pasteboard.changeCount == count)
        #expect(pasteboard.string(forType: .string) == "keep this")
    }

    private func svg(width: Int, height: Int, content: String = "<rect width='4' height='3' fill='red'/>") -> Data {
        Data("<svg xmlns='http://www.w3.org/2000/svg' width='\(width)' height='\(height)'>\(content)</svg>".utf8)
    }
}
