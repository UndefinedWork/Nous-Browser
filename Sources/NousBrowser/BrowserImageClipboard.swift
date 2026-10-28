import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// Fallback for a native Copy Image action that left the pasteboard unchanged.
/// WebKit performs the request so authenticated images keep their browser session.
@MainActor
final class BrowserImageClipboard: NSObject, WKDownloadDelegate {
    static let shared = BrowserImageClipboard()
    static let maximumBytes = 32 * 1024 * 1024
    static let maximumPixels = 16_000_000
    static let maximumEdge = 8_192

    enum Failure: Error, Equatable {
        case invalidURL, unsupportedResponse, tooLarge, invalidImage, unsupportedDimensions
        case timedOut, clipboardWriteFailed
    }

    struct EncodedImage {
        let png: Data
        let tiff: Data
        let width: Int
        let height: Int
    }

    @MainActor private final class Job {
        let id = UUID()
        weak var webView: WKWebView?
        let pageURL: URL?
        let pasteboard: NSPasteboard
        let expectedChangeCount: Int
        let isValid: @MainActor () -> Bool
        let completion: @MainActor (Result<Bool, Error>) -> Void
        let directory: URL
        var file: URL { directory.appendingPathComponent("image") }
        var download: WKDownload?
        var observation: NSKeyValueObservation?
        var monitor: Task<Void, Never>?

        init(webView: WKWebView, pasteboard: NSPasteboard, expectedChangeCount: Int,
             directory: URL, isValid: @escaping @MainActor () -> Bool,
             completion: @escaping @MainActor (Result<Bool, Error>) -> Void) {
            self.webView = webView
            pageURL = webView.url
            self.pasteboard = pasteboard
            self.expectedChangeCount = expectedChangeCount
            self.directory = directory
            self.isValid = isValid
            self.completion = completion
        }

        var remainsValid: Bool {
            guard let webView else { return false }
            return webView.url == pageURL && isValid() && pasteboard.changeCount == expectedChangeCount
        }
    }

    private var jobs: [UUID: Job] = [:]

    /// true means copied; false means superseded/cancelled and should stay silent.
    func copyImage(from url: URL, in webView: WKWebView, pasteboard: NSPasteboard = .general,
                   expectedChangeCount: Int, isValid: @escaping @MainActor () -> Bool = { true },
                   completion: @escaping @MainActor (Result<Bool, Error>) -> Void) {
        for job in Array(jobs.values) where job.pasteboard.name == pasteboard.name {
            finish(job.id, result: .success(false))
        }
        guard isValid(), pasteboard.changeCount == expectedChangeCount else {
            completion(.success(false)); return
        }
        guard Self.acceptsURL(url) else { completion(.failure(Failure.invalidURL)); return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NousImageCopy-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { completion(.failure(error)); return }
        let job = Job(webView: webView, pasteboard: pasteboard, expectedChangeCount: expectedChangeCount,
                      directory: directory, isValid: isValid, completion: completion)
        jobs[job.id] = job
        let id = job.id
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        job.monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, let job = self.jobs[id] else { return }
                guard job.remainsValid else {
                    self.finish(id, result: .success(false)); return
                }
                if ContinuousClock.now >= deadline {
                    self.finish(id, result: .failure(Failure.timedOut)); return
                }
                self.checkProgress(id)
            }
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        webView.startDownload(using: request) { [weak self, weak job] download in
            guard let self, let job, self.jobs[id] === job, job.remainsValid else {
                download.cancel(nil)
                self?.finish(id, result: .success(false))
                return
            }
            job.download = download
            download.delegate = self
            job.observation = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.checkProgress(id) }
            }
        }
    }

    func cancel(for webView: WKWebView) {
        for job in Array(jobs.values) where job.webView === webView {
            finish(job.id, result: .success(false))
        }
    }

    private func checkProgress(_ id: UUID) {
        guard let job = jobs[id] else { return }
        guard job.remainsValid else { finish(id, result: .success(false)); return }
        let fileBytes = (try? job.file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if fileBytes > Self.maximumBytes || (job.download?.progress.completedUnitCount ?? 0) > Self.maximumBytes {
            finish(id, result: .failure(Failure.tooLarge))
        }
    }

    private func job(for download: WKDownload) -> Job? {
        jobs.values.first { $0.download === download }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard let job = job(for: download) else { completionHandler(nil); return }
        guard job.remainsValid else {
            completionHandler(nil); finish(job.id, result: .success(false)); return
        }
        do { try Self.validateResponse(response) }
        catch {
            completionHandler(nil); finish(job.id, result: .failure(error)); return
        }
        completionHandler(job.file)
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  decisionHandler: @escaping @MainActor @Sendable (WKDownload.RedirectPolicy) -> Void) {
        guard let job = job(for: download), job.remainsValid,
              let url = request.url, Self.acceptsURL(url) else {
            decisionHandler(.cancel)
            if let job = job(for: download) { finish(job.id, result: .success(false)) }
            return
        }
        decisionHandler(.allow)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let job = job(for: download) else { return }
        guard job.remainsValid else { finish(job.id, result: .success(false), cancel: false); return }
        do {
            let size = try job.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maximumBytes else { throw Failure.tooLarge }
            let data = try Data(contentsOf: job.file, options: .mappedIfSafe)
            let image = try Self.encode(data)
            let copied = try Self.write(image, to: job.pasteboard, expectedChangeCount: job.expectedChangeCount,
                                        isValid: { job.remainsValid })
            finish(job.id, result: .success(copied), cancel: false)
        } catch { finish(job.id, result: .failure(error), cancel: false) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let job = job(for: download) else { return }
        finish(job.id, result: job.remainsValid ? .failure(error) : .success(false), cancel: false)
    }

    private func finish(_ id: UUID, result: Result<Bool, Error>, cancel: Bool = true) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        job.monitor?.cancel()
        job.observation?.invalidate()
        job.download?.delegate = nil
        if cancel, let download = job.download {
            let directory = job.directory
            download.cancel { _ in try? FileManager.default.removeItem(at: directory) }
        }
        try? FileManager.default.removeItem(at: job.directory)
        job.completion(result)
    }

    static func acceptsURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil else { return false }
        switch components.scheme?.lowercased() {
        case "http", "https": return !(components.host ?? "").isEmpty
        case "blob", "data": return true // Trusted frame URL validation belongs to the context-menu capture.
        default: return false
        }
    }

    static func validateResponse(_ response: URLResponse) throws {
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            throw Failure.unsupportedResponse
        }
        let mime = response.mimeType?.lowercased() ?? ""
        guard mime.hasPrefix("image/") || mime == "application/octet-stream" else {
            throw Failure.unsupportedResponse
        }
        guard response.expectedContentLength <= maximumBytes else { throw Failure.tooLarge }
    }

    /// Rasterize once at pixel dimensions. NSImage.tiffRepresentation can create
    /// many oversized representations for SVG; never use it as an intermediate.
    static func encode(_ data: Data) throws -> EncodedImage {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        var pixelSize: CGSize?
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let rawType = CGImageSourceGetType(source), let type = UTType(rawType as String), type.conforms(to: .image) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            if let width = properties?[kCGImagePropertyPixelWidth] as? NSNumber,
               let height = properties?[kCGImagePropertyPixelHeight] as? NSNumber {
                pixelSize = CGSize(width: width.doubleValue, height: height.doubleValue)
                try validateSize(pixelSize!)
            }
        } else {
            let probe = SVGRootProbe()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = probe
            _ = parser.parse()
            guard probe.isSVG else { throw Failure.invalidImage }
        }
        guard let source = NSImage(data: data), !source.representations.contains(where: { $0 is NSPDFImageRep }) else {
            throw Failure.invalidImage
        }
        let size = pixelSize ?? source.size
        try validateSize(size)
        let width = Int(ceil(size.width)), height = Int(ceil(size.height))
        guard let storage = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bitmap = storage.retagging(with: .sRGB),
              let context = NSGraphicsContext(bitmapImageRep: bitmap), let bytes = bitmap.bitmapData else {
            throw Failure.invalidImage
        }
        bitmap.size = NSSize(width: width, height: height)
        memset(bytes, 0, bitmap.bytesPerRow * height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero,
                    operation: .copy, fraction: 1, respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]),
              let tiff = bitmap.representation(using: .tiff, properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue]) else {
            throw Failure.invalidImage
        }
        return EncodedImage(png: png, tiff: tiff, width: width, height: height)
    }

    private static func validateSize(_ size: CGSize) throws {
        let width = ceil(size.width), height = ceil(size.height)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= CGFloat(maximumEdge), height <= CGFloat(maximumEdge),
              width * height <= CGFloat(maximumPixels) else { throw Failure.unsupportedDimensions }
    }

    /// Build both representations before touching the pasteboard. No await is
    /// allowed between the final change-count check and this synchronous write.
    static func write(_ image: EncodedImage, to pasteboard: NSPasteboard, expectedChangeCount: Int,
                      isValid: @MainActor () -> Bool = { true }) throws -> Bool {
        let item = NSPasteboardItem()
        guard item.setData(image.png, forType: .png), item.setData(image.tiff, forType: .tiff) else {
            throw Failure.clipboardWriteFailed
        }
        guard isValid(), pasteboard.changeCount == expectedChangeCount else { return false }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw Failure.clipboardWriteFailed }
        return true
    }
}

private final class SVGRootProbe: NSObject, XMLParserDelegate {
    var isSVG = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        isSVG = elementName == "svg" || elementName.hasSuffix(":svg")
        parser.abortParsing()
    }
}
