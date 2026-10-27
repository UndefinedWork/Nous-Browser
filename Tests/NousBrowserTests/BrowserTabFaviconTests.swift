import AppKit
import Foundation
import Testing
import WebKit
@testable import NousBrowser

@Suite("Live tab document icons", .serialized)
@MainActor
struct BrowserTabFaviconTests {
    @Test func updatesAfterLoadAndKeepsOtherDocumentsDistinct() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = BrowserModel(sessionURL: directory.appendingPathComponent("session.json"), restoreSession: false, startWithBlankTab: true)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let first = try #require(model.selectedTab)
        let base = URL(string: "http://127.0.0.1:9/" + UUID().uuidString)!
        first.url = base
        first.webView.loadHTMLString("<html><head><title>First</title><link id='icon' rel='icon' href='\(icon("red"))'></head><body>First document</body></html>", baseURL: base)
        try await wait { isColor(first.favicon, red: true) }
        // This reproduces a document's late response: the browser has already
        // finished loading when its favicon changes, without any navigation.
        try await first.webView.evaluateJavaScript("document.getElementById('icon').href='\(icon("blue"))'")
        try await wait { isColor(first.favicon, red: false) }

        model.newTab()
        let second = try #require(model.selectedTab)
        let secondURL = base.appendingPathComponent("second")
        second.url = secondURL
        second.webView.loadHTMLString("<html><head><title>Second</title><link rel='icon' href='\(icon("red"))'></head><body>Second document</body></html>", baseURL: secondURL)
        try await wait { isColor(second.favicon, red: true) }
        #expect(isColor(first.favicon, red: false))
        #expect(isColor(FaviconStore.shared.cachedImage(for: base), red: false))
        #expect(isColor(FaviconStore.shared.cachedImage(for: secondURL), red: true))
    }

    private func icon(_ color: String) -> String {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='\(color)'/></svg>"
        return "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
    }

    private func isColor(_ image: NSImage?, red: Bool) -> Bool {
        guard let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else { return false }
        return red ? color.redComponent > 0.9 && color.blueComponent < 0.1 : color.blueComponent > 0.9 && color.redComponent < 0.1
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        #expect(condition())
        try #require(condition())
    }
}
