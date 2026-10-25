import AppKit
import Foundation
import Testing
@testable import NousBrowser

@Suite("Website icon cache")
struct FaviconStoreTests {
    @Test @MainActor func restoresDistinctIconsForPagesOnTheSameSite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FaviconStore(directory: directory)
        let first = URL(string: "https://example.test/first")!
        let second = URL(string: "https://example.test/second")!
        let red = await store.image(for: first, candidates: [icon("red")])
        let blue = await store.image(for: second, candidates: [icon("blue")])
        #expect(isRed(try #require(red)))
        #expect(!isRed(try #require(blue)))

        // A fresh store must recover the page-specific images from disk,
        // including when the restored tab points to an anchor on that page.
        let restored = FaviconStore(directory: directory)
        #expect(isRed(try #require(restored.cachedImage(for: URL(string: first.absoluteString + "#heading")!))))
        #expect(!isRed(try #require(restored.cachedImage(for: second))))
    }

    @Test @MainActor func declaredIconReplacesAnEarlierCachedIcon() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FaviconStore(directory: directory)
        let page = URL(string: "https://example.test/page")!
        _ = await store.image(for: page, candidates: [icon("red")])
        let replacement = await store.image(for: page, candidates: [icon("blue")])
        #expect(!isRed(try #require(replacement)))
        let restored = FaviconStore(directory: directory)
        #expect(!isRed(try #require(restored.cachedImage(for: page))))
    }

    private func icon(_ color: String) -> URL {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='\(color)'/></svg>"
        return URL(string: "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString())!
    }

    @MainActor private func isRed(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else { return false }
        return color.redComponent > color.blueComponent
    }
}
