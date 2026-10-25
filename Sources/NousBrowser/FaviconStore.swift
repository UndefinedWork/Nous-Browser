import AppKit
import CryptoKit
import Foundation
import ImageIO

/// Fetches icons directly from the visited site or its declared icon URL.
/// Cached thumbnails keep restored, unloaded tabs recognizable without loading pages.
@MainActor
final class FaviconStore {
    static let shared = FaviconStore()

    private struct Record: Codable, Equatable {
        let sourceURL: URL
        let storedAt: Date
    }

    private let directory: URL
    private let session: URLSession
    private let images = NSCache<NSString, NSImage>()
    private var records: [String: Record] = [:]
    private var sourceDates: [String: Date] = [:]
    private var downloads: [String: Task<Data?, Never>] = [:]
    private var failures: [String: Date] = [:]
    private let lifetime: TimeInterval = 7 * 24 * 60 * 60
    nonisolated private static let maximumBytes = 2 * 1024 * 1024

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nous Browser/Favicons", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0)
        session = URLSession(configuration: configuration)
        images.countLimit = 128
    }

    func cachedImage(for pageURL: URL) -> NSImage? {
        cachedEntry(for: pageURL)?.image
    }

    private func cachedEntry(for pageURL: URL) -> (image: NSImage, record: Record?)? {
        guard let key = pageKey(pageURL), let origin = originKey(pageURL) else { return nil }
        if let image = cachedImage(forKey: key) {
            let record = cachedRecord(key)
            // Old releases wrote exact-page files only. Backfill their origin
            // on a hit, without scanning disk or renewing the seven-day age.
            if let record,
               cachedImage(forKey: origin) == nil || (cachedRecord(origin).map({ $0.storedAt < record.storedAt }) ?? true) {
                cache(image, key: origin, record: record)
            }
            return (image, record)
        }
        guard let image = cachedImage(forKey: origin) else { return nil }
        return (image, cachedRecord(origin))
    }

    private func cachedImage(forKey key: String) -> NSImage? {
        if let image = images.object(forKey: key as NSString) { return image }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".png")),
              let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: key as NSString)
        return image
    }

    func image(for pageURL: URL, candidates: [URL] = []) async -> NSImage? {
        guard let key = pageKey(pageURL), let origin = originKey(pageURL) else { return nil }
        let entry = cachedEntry(for: pageURL)
        let cached = entry?.image
        let record = entry?.record
        let fresh = record.map { Date().timeIntervalSince($0.storedAt) < lifetime } ?? false
        if candidates.isEmpty, fresh, let cached { return cached }

        let preferred = candidates.isEmpty ? record.map { [$0.sourceURL] } ?? [] : candidates
        var seen = Set<URL>()
        var urls = preferred.filter {
            guard ["http", "https", "data"].contains($0.scheme?.lowercased() ?? ""),
                  $0.user == nil, $0.password == nil else { return false }
            return seen.insert($0).inserted
        }
        urls = Array(urls.prefix(8))
        if let root = rootIconURL(for: pageURL), seen.insert(root).inserted { urls.append(root) }

        for url in urls {
            guard !Task.isCancelled else { return cached }
            // A previously cached root icon must not mask a newly declared icon.
            if fresh, record?.sourceURL == url, let cached { return cached }
            let sourceKey = Self.digest(url.absoluteString)
            if let date = sourceDates[sourceKey], Date().timeIntervalSince(date) < lifetime,
               let image = images.object(forKey: sourceKey as NSString) {
                store(image, pageKey: key, originKey: origin, sourceURL: url, storedAt: date)
                return image
            }
            if let failed = failures[sourceKey], Date().timeIntervalSince(failed) < 300 { continue }
            let task: Task<Data?, Never>
            if let existing = downloads[sourceKey] {
                task = existing
            } else {
                let session = session
                task = Task { await Self.download(url, using: session) }
                downloads[sourceKey] = task
            }
            let data = await task.value
            downloads[sourceKey] = nil
            // A canceled fallback request must not overwrite a newer declared icon.
            guard !Task.isCancelled else { return cached }
            // A suggestion's uncancelled root request can finish after the live
            // page has supplied its declared icon. Keep that newer success.
            if candidates.isEmpty, let latest = cachedEntry(for: pageURL),
               let latestRecord = latest.record, latestRecord != record,
               Date().timeIntervalSince(latestRecord.storedAt) < lifetime {
                return latest.image
            }
            guard let data, let image = Self.thumbnail(data) else {
                failures[sourceKey] = Date()
                if failures.count > 256 { failures.removeAll(keepingCapacity: true) }
                continue
            }
            images.setObject(image, forKey: sourceKey as NSString)
            sourceDates[sourceKey] = Date()
            store(image, pageKey: key, originKey: origin, sourceURL: url)
            return image
        }
        return cached
    }

    private func cachedRecord(_ key: String) -> Record? {
        if let record = records[key] { return record }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".json")),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        records[key] = record
        return record
    }

    private func store(_ image: NSImage, pageKey key: String, originKey: String, sourceURL: URL, storedAt: Date = Date()) {
        let record = Record(sourceURL: sourceURL, storedAt: storedAt)
        cache(image, key: key, record: record)
        cache(image, key: originKey, record: record)
    }

    private func cache(_ image: NSImage, key: String, record: Record) {
        images.setObject(image, forKey: key as NSString)
        records[key] = record
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent(key + ".png"), options: .atomic)
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(key + ".json"), options: .atomic)
        } catch {
            // A missing disk cache must never interfere with browsing.
        }
    }

    private func pageKey(_ url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let value = components.url?.absoluteString else { return nil }
        return Self.digest(value)
    }

    private func originKey(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        return Self.digest("origin:\(scheme)://\(host):\(port)")
    }

    private func rootIconURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    nonisolated private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func download(_ url: URL, using session: URLSession) async -> Data? {
        if url.scheme?.lowercased() == "data" {
            let value = url.absoluteString
            guard value.utf8.count <= maximumBytes * 2,
                  let comma = value.firstIndex(of: ",") else { return nil }
            let header = value[..<comma].lowercased()
            guard header.hasPrefix("data:image/") else { return nil }
            let body = String(value[value.index(after: comma)...])
            let data = header.contains(";base64")
                ? Data(base64Encoded: body.removingPercentEncoding ?? body)
                : body.removingPercentEncoding?.data(using: .utf8)
            guard let data, data.count <= maximumBytes else { return nil }
            return data
        }
        var request = URLRequest(url: url)
        request.setValue("image/avif,image/webp,image/png,image/svg+xml,image/x-icon,image/*;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode), response.expectedContentLength <= maximumBytes else { return nil }
            if let type = response.mimeType, type == "text/html" || type == "application/xhtml+xml" { return nil }
            var data = Data()
            for try await byte in bytes {
                guard !Task.isCancelled, data.count < maximumBytes else { return nil }
                data.append(byte)
            }
            return data.isEmpty ? nil : data
        } catch { return nil }
    }

    private static func thumbnail(_ data: Data) -> NSImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceCreateThumbnailWithTransform: true
           ] as CFDictionary) {
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        // AppKit also decodes vector icons on supported system versions.
        guard let source = NSImage(data: data), source.size.width > 0, source.size.height > 0 else { return nil }
        let size = NSSize(width: 64, height: 64)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let factor = min(size.width / source.size.width, size.height / source.size.height)
        let rect = NSRect(x: (size.width - source.size.width * factor) / 2,
                          y: (size.height - source.size.height * factor) / 2,
                          width: source.size.width * factor, height: source.size.height * factor)
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }
}
