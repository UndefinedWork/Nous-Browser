import AppKit
import CryptoKit
import Foundation
import Testing
@testable import NousBrowser

@Suite("Website icon cache")
struct FaviconStoreTests {
    @Test @MainActor func restoresDistinctIconsForPagesOnTheSameSite() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FaviconStore(directory: directory)
        let first = URL(string: "https://example.test/first")!
        let second = URL(string: "https://example.test/second")!
        let red = await store.image(for: first, candidates: [icon("red")])
        let blue = await store.image(for: second, candidates: [icon("blue")])
        #expect(isRed(try #require(red)))
        #expect(!isRed(try #require(blue)))
        let restored = FaviconStore(directory: directory)
        #expect(isRed(try #require(restored.cachedImage(for: URL(string: first.absoluteString + "#heading")!))))
        #expect(!isRed(try #require(restored.cachedImage(for: second))))
        #expect(restored.cachedImage(for: URL(string: "https://example.test/third")!) == nil)
    }

    @Test @MainActor func declaredIconReplacesAnEarlierCachedIcon() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FaviconStore(directory: directory)
        let page = URL(string: "https://example.test/page")!
        _ = await store.image(for: page, candidates: [icon("red")])
        let replacement = await store.image(for: page, candidates: [icon("blue")])
        #expect(!isRed(try #require(replacement)))
        let restored = FaviconStore(directory: directory)
        #expect(!isRed(try #require(restored.cachedImage(for: page))))
    }

    @Test @MainActor func documentIconsNeverBecomeAnOriginFallback() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FaviconStore(directory: directory)
        let first = URL(string: "https://example.test/first?article=one#first")!
        _ = await store.image(for: first, candidates: [icon("red")])
        for cache in [store, FaviconStore(directory: directory)] {
            #expect(isRed(try #require(cache.cachedImage(for: first))))
            for address in ["https://example.test/second?article=two", "https://EXAMPLE.test:443/third", "https://example.test/first?article=two"] {
                #expect(cache.cachedImage(for: URL(string: address)!) == nil)
            }
        }
    }

    @Test @MainActor func fragmentDocumentsKeepExactIconsAndAnchorsCanUseTheBase() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = URL(string: "https://example.test/docs")!
        let star = URL(string: "https://example.test/docs#/star")!
        let heart = URL(string: "https://example.test/docs#/heart")!
        let store = FaviconStore(directory: directory)
        _ = await store.image(for: base, candidates: [icon("green")])
        _ = await store.image(for: star, candidates: [icon("red")])
        _ = await store.image(for: heart, candidates: [icon("blue")])
        let restored = FaviconStore(directory: directory)
        #expect(isRed(try #require(restored.cachedImage(for: star))))
        #expect(!isRed(try #require(restored.cachedImage(for: heart))))
        let baseImage = try #require(restored.cachedImage(for: base))
        let anchorImage = try #require(restored.cachedImage(for: URL(string: base.absoluteString + "#heading")!))
        #expect(baseImage.tiffRepresentation == anchorImage.tiffRepresentation)
    }

    @Test @MainActor func onlyRootIconsAreSharedAcrossPagesAndRestart() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = URL(string: "https://example.test:8443/first")!
        try writeLegacyCache(directory: directory, page: page, source: URL(string: "https://example.test:8443/favicon.ico")!)
        let store = FaviconStore(directory: directory)
        #expect(isRed(try #require(store.cachedImage(for: page))))
        for cache in [store, FaviconStore(directory: directory)] {
            let other = URL(string: "https://EXAMPLE.test:8443/other")!
            #expect(isRed(try #require(cache.cachedImage(for: other))))
            #expect(isRed(try #require(await cache.image(for: other))))
            for address in ["https://other.test:8443/other", "https://example.test/other", "http://example.test:8443/other"] {
                #expect(cache.cachedImage(for: URL(string: address)!) == nil)
            }
        }
    }

    @Test @MainActor func declaredIconWinsOverRootWithoutReplacingOtherPagesRootFallback() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyPage = URL(string: "https://example.test/legacy")!
        try writeLegacyCache(directory: directory, page: legacyPage, source: URL(string: "https://example.test/favicon.ico")!)
        let store = FaviconStore(directory: directory)
        #expect(isRed(try #require(store.cachedImage(for: legacyPage))))
        let page = URL(string: "https://example.test/new-page")!
        #expect(isRed(try #require(store.cachedImage(for: page))))
        let declared = try #require(await store.image(for: page, candidates: [icon("blue")]))
        #expect(!isRed(declared))
        let cold = FaviconStore(directory: directory)
        #expect(!isRed(try #require(cold.cachedImage(for: page))))
        #expect(isRed(try #require(cold.cachedImage(for: URL(string: "https://example.test/another-page")!))))
    }

    @Test @MainActor func ignoresLegacyOriginRecordsContainingDocumentIcons() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = URL(string: "https://example.test/legacy")!
        let source = icon("red")
        try writeLegacyCache(directory: directory, page: page, source: source)
        try writeCache(directory: directory, key: digest("origin:https://example.test:443"), source: source)
        let store = FaviconStore(directory: directory)
        #expect(isRed(try #require(store.cachedImage(for: page))))
        #expect(store.cachedImage(for: URL(string: "https://example.test/other")!) == nil)
        let restored = FaviconStore(directory: directory)
        #expect(restored.cachedImage(for: URL(string: "https://example.test/other")!) == nil)
    }

    @Test @MainActor func failedDeclaredCandidateDoesNotMaskTheNextCandidateWithCachedRoot() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = URL(string: "https://example.test/page")!
        try writeLegacyCache(directory: directory, page: page, source: URL(string: "https://example.test/favicon.ico")!)
        let store = FaviconStore(directory: directory)
        let badImage = URL(string: "data:image/png;base64,bm90LWFuLWltYWdl")!
        #expect(await store.image(for: page, candidates: [badImage], allowRootFallback: false) == nil)
        #expect(!isRed(try #require(await store.image(for: page, candidates: [icon("blue")], allowRootFallback: false))))
        #expect(!isRed(try #require(store.cachedImage(for: page))))
    }

    @Test @MainActor func failedDeclaredDataCanStillUseRootWhenFallbackAllowed() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = URL(string: "https://example.test/page")!
        try writeLegacyCache(directory: directory, page: page, source: URL(string: "https://example.test/favicon.ico")!)
        let store = FaviconStore(directory: directory)
        let badImage = URL(string: "data:image/png;base64,bm90LWFuLWltYWdl")!
        #expect(isRed(try #require(await store.image(for: page, candidates: [badImage]))))
    }

    @Test @MainActor func removingTheDeclaredIconRestoresRootAndPersistsIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = URL(string: "https://example.test/page")!
        try writeLegacyCache(directory: directory, page: page, source: URL(string: "https://example.test/favicon.ico")!)
        let store = FaviconStore(directory: directory)
        #expect(isRed(try #require(store.cachedImage(for: page))))
        _ = await store.image(for: page, candidates: [icon("blue")])
        #expect(!isRed(try #require(store.cachedImage(for: page))))
        #expect(isRed(try #require(await store.image(for: page, usePageCache: false))))
        let restored = FaviconStore(directory: directory)
        #expect(isRed(try #require(restored.cachedImage(for: page))))
    }

    @Test @MainActor func canceledEmptyDeclarationCannotOverwriteANewerDocumentIconWithRoot() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = URL(string: "https://example.test/page")!
        try writeLegacyCache(directory: directory, page: page, source: URL(string: "https://example.test/favicon.ico")!)
        let store = FaviconStore(directory: directory)
        #expect(isRed(try #require(store.cachedImage(for: page))))
        _ = await store.image(for: page, candidates: [icon("blue")])
        // Inherits MainActor: cancellation happens before the task can enter
        // image(), reproducing a queued empty declaration superseded by a new icon.
        let obsolete = Task { await store.image(for: page, usePageCache: false) }
        obsolete.cancel()
        #expect(await obsolete.value == nil)
        #expect(!isRed(try #require(store.cachedImage(for: page))))
        #expect(!isRed(try #require(FaviconStore(directory: directory).cachedImage(for: page))))
    }

    @Test @MainActor func removedIconDoesNotReappearWhenRootIsMissing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MissingFaviconProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let store = FaviconStore(directory: directory, session: session)
        let base = URL(string: "https://example.test/docs")!
        let page = URL(string: "https://example.test/docs#/removed")!
        _ = await store.image(for: base, candidates: [icon("blue")])
        _ = await store.image(for: page, candidates: [icon("red")])
        #expect(isRed(try #require(store.cachedImage(for: page))))
        #expect(await store.image(for: page, usePageCache: false) == nil)
        #expect(store.cachedImage(for: page) == nil)
        let restored = FaviconStore(directory: directory)
        #expect(restored.cachedImage(for: page) == nil)
        #expect(restored.cachedImage(for: base) != nil)
    }

    @Test @MainActor func pageRenderedBlobPersistsPixelsWithoutItsTransientURL() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = URL(string: "https://example.test/docs#/star")!
        let source = URL(string: "blob:https://example.test/ephemeral-document-icon")!
        let store = FaviconStore(directory: directory)
        #expect(isRed(try #require(store.storePageImage(try redPNG(), for: page, sourceURL: source))))
        let restored = FaviconStore(directory: directory)
        #expect(isRed(try #require(restored.cachedImage(for: page))))
        #expect(isRed(try #require(await restored.image(for: page))))
        #expect(restored.cachedImage(for: URL(string: "https://example.test/docs#/other")!) == nil)
        let metadataFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        #expect(metadataFiles.count == 1)
        for file in metadataFiles {
            #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("ephemeral-document-icon"))
        }
    }

    @Test @MainActor func pageRenderedImagesValidateDataAndSource() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FaviconStore(directory: directory)
        let page = URL(string: "https://example.test/page")!
        #expect(store.storePageImage(Data("invalid".utf8), for: page, sourceURL: icon("red")) == nil)
        #expect(store.storePageImage(Data(count: 2 * 1024 * 1024 + 1), for: page, sourceURL: icon("red")) == nil)
        #expect(store.storePageImage(try redPNG(), for: page, sourceURL: URL(string: "file:///private/icon.png")!) == nil)
        #expect(store.storePageImage(try redPNG(), for: page, sourceURL: URL(string: "https://user:secret@example.test/icon.png")!) == nil)
        #expect(store.cachedImage(for: page) == nil)
    }

    @Test @MainActor func legacyRootBackfillPreservesTheOriginalSevenDayExpiry() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = URL(string: "https://example.test/legacy")!
        let storedAt = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        try writeLegacyCache(directory: directory, page: page, source: URL(string: "https://example.test/favicon.ico")!, storedAt: storedAt)
        let store = FaviconStore(directory: directory)
        #expect(isRed(try #require(store.cachedImage(for: page))))
        let records = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
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

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor private func writeLegacyCache(directory: URL, page: URL, source: URL, storedAt: Date = Date()) throws {
        var components = try #require(URLComponents(url: page, resolvingAgainstBaseURL: false))
        components.fragment = nil
        components.user = nil
        components.password = nil
        try writeCache(directory: directory, key: digest(try #require(components.url?.absoluteString)), source: source, storedAt: storedAt)
    }

    @MainActor private func writeCache(directory: URL, key: String, source: URL, storedAt: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try redPNG().write(to: directory.appendingPathComponent(key + ".png"))
        try JSONEncoder().encode(LegacyRecord(sourceURL: source, storedAt: storedAt)).write(to: directory.appendingPathComponent(key + ".json"))
    }

    @MainActor private func redPNG() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(red, atX: x, y: y) } }
        return try #require(bitmap.representation(using: .png, properties: [:]))
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

private final class MissingFaviconProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
