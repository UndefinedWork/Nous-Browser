import AppKit
import CryptoKit
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

    @Test @MainActor func reusesSuccessfulIconsForDifferentPagesAndAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FaviconStore(directory: directory)
        let first = URL(string: "https://example.test/first?article=one#first")!
        _ = await store.image(for: first, candidates: [icon("red")])
        let second = URL(string: "https://example.test/second?article=two#second")!
        #expect(isRed(try #require(store.cachedImage(for: second))))
        #expect(isRed(try #require(store.cachedImage(for: URL(string: "https://EXAMPLE.test:443/third")!))))
        #expect(isRed(try #require(await store.image(for: second))))

        let restored = FaviconStore(directory: directory)
        #expect(isRed(try #require(restored.cachedImage(for: second))))
        #expect(isRed(try #require(await restored.image(for: URL(string: "https://example.test/fourth")!))))
    }

    @Test @MainActor func neverSharesOriginFallbackAcrossHostSchemeOrPort() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FaviconStore(directory: directory)
        _ = await store.image(for: URL(string: "https://example.test:8443/first")!, candidates: [icon("red")])
        let restored = FaviconStore(directory: directory)
        for cache in [store, restored] {
            #expect(isRed(try #require(cache.cachedImage(for: URL(string: "https://example.test:8443/other")!))))
            for address in ["https://other.test:8443/other", "https://example.test/other", "http://example.test:8443/other"] {
                #expect(cache.cachedImage(for: URL(string: address)!) == nil)
            }
        }
    }

    @Test @MainActor func aDeclaredIconWinsOverAnOriginCachedRootAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyPage = URL(string: "https://example.test/legacy")!
        try writeLegacyCache(directory: directory, page: legacyPage, source: URL(string: "https://example.test/favicon.ico")!)
        let store = FaviconStore(directory: directory)
        #expect(isRed(try #require(store.cachedImage(for: legacyPage))))

        let restored = FaviconStore(directory: directory)
        let page = URL(string: "https://example.test/new-page")!
        #expect(isRed(try #require(restored.cachedImage(for: page))))
        let declared = try #require(await restored.image(for: page, candidates: [icon("blue")]))
        #expect(!isRed(declared))
        let cold = FaviconStore(directory: directory)
        #expect(!isRed(try #require(cold.cachedImage(for: URL(string: "https://example.test/another-page")!))))
        // Reading an older exact-page icon cannot replace the newer origin icon.
        #expect(isRed(try #require(cold.cachedImage(for: legacyPage))))
        #expect(!isRed(try #require(cold.cachedImage(for: URL(string: "https://example.test/yet-another-page")!))))
    }

    @Test @MainActor func failedDeclaredDataKeepsTheSuccessfulCachedRoot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = URL(string: "https://example.test/page")!
        try writeLegacyCache(directory: directory, page: page, source: URL(string: "https://example.test/favicon.ico")!)
        let store = FaviconStore(directory: directory)
        // The fresh root record short-circuits its fallback URL, so this test
        // exercises invalid image data without sending any network request.
        let badImage = URL(string: "data:image/png;base64,bm90LWFuLWltYWdl")!
        #expect(isRed(try #require(await store.image(for: page, candidates: [badImage]))))
        let restored = FaviconStore(directory: directory)
        #expect(isRed(try #require(restored.cachedImage(for: URL(string: "https://example.test/next")!))))
    }

    @Test @MainActor func legacyBackfillPreservesTheOriginalSevenDayExpiry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = URL(string: "https://example.test/legacy")!
        let storedAt = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        try writeLegacyCache(directory: directory, page: page,
                             source: URL(string: "https://example.test/favicon.ico")!, storedAt: storedAt)
        let store = FaviconStore(directory: directory)
        #expect(isRed(try #require(store.cachedImage(for: page))))
        let records = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(records.count == 2)
        for file in records {
            let value = try JSONDecoder().decode(LegacyRecord.self, from: Data(contentsOf: file))
            #expect(value.storedAt == storedAt)
        }
    }

    private struct LegacyRecord: Codable {
        let sourceURL: URL
        let storedAt: Date
    }

    @MainActor private func writeLegacyCache(directory: URL, page: URL, source: URL, storedAt: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var components = try #require(URLComponents(url: page, resolvingAgainstBaseURL: false))
        components.fragment = nil
        components.user = nil
        components.password = nil
        let address = try #require(components.url?.absoluteString)
        let key = SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(red, atX: x, y: y) } }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(key + ".png"))
        try JSONEncoder().encode(LegacyRecord(sourceURL: source, storedAt: storedAt))
            .write(to: directory.appendingPathComponent(key + ".json"))
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
