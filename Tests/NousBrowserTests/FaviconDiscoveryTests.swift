import AppKit
import Darwin
import Foundation
import Testing
@testable import NousBrowser

@Suite("Shortcut declared favicons", .serialized)
@MainActor
struct FaviconDiscoveryTests {
    @Test func parsesOnlyHeadWithRelTokensBaseEntitiesAndTreeOrder() {
        let html = #"""
        <!doctype html><HTML><HEAD>
        <!-- <link rel=icon href=/comment.png> -->
        <BASE HREF="../assets/"><base href="/ignored/">
        <link rel="apple-touch-icon" href="touch.png">
        <link rel="shortcut ICON" href="first.png">
        <script>const bait = '</head><link rel=icon href=/script.png>';</script>
        <link rel=icon href="last.png?a=1&amp;b=2">
        <link rel=icon href="file:///private/bad.png">
        </HEAD><BODY><link rel=icon href="/body.png"></BODY></HTML>
        """#
        let urls = FaviconDiscovery.candidates(in: Data(html.utf8), documentURL: URL(string: "https://example.test/hub/index.html")!)
        #expect(urls.map(\.absoluteString) == ["https://example.test/assets/last.png?a=1&b=2", "https://example.test/assets/first.png", "https://example.test/assets/touch.png"])
    }

    @Test func redirectAndDirectEntryDiscoverPNGWithoutSharingDocumentIcons() async throws {
        let server = try await IconPageServer()
        defer { server.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FaviconStore(directory: directory)
        let document = server.url.appendingPathComponent("document/star")
        _ = store.storePageImage(try redPNG(), for: document, sourceURL: URL(string: "data:image/png;base64,star")!)
        let shortcut = server.url.appendingPathComponent("shortcut")
        #expect(isBlue(try #require(await store.quickLinkImage(for: shortcut))))
        #expect(isBlue(try #require(FaviconStore(directory: directory).cachedImage(for: shortcut))))
        #expect(!isBlue(try #require(store.cachedImage(for: document))))
        #expect(store.cachedImage(for: server.url.appendingPathComponent("other-document")) == nil)
        #expect(isBlue(try #require(await store.quickLinkImage(for: server.url.appendingPathComponent("hub/index.html")))))
        // A shortcut's already-cached /favicon.ico must not hide the declaration.
        let legacy = server.url.appendingPathComponent("legacy")
        _ = store.storePageImage(try redPNG(), for: legacy, sourceURL: server.url.appendingPathComponent("favicon.ico"))
        #expect(isBlue(try #require(await store.quickLinkImage(for: legacy))))
        #expect(isBlue(try #require(await store.quickLinkImage(for: server.url.appendingPathComponent("large-body")))))
    }

    @Test func htmlRootFallbackIsRejectedAndFailuresAreThrottled() async throws {
        let server = try await IconPageServer()
        defer { server.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FaviconStore(directory: directory)
        let page = server.url.appendingPathComponent("no-icon")
        #expect(await store.quickLinkImage(for: page) == nil)
        #expect(await store.quickLinkImage(for: page) == nil)
        let counts = try await server.counts()
        #expect(counts["/no-icon"] == 1)
        #expect(counts["/favicon.ico"] == 1)
    }

    @Test func lateHTMLAndImageResultsCannotReplaceALiveDocumentIcon() async throws {
        let server = try await IconPageServer()
        defer { server.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FaviconStore(directory: directory)
        for (path, requestPath) in [("slow-page", "/slow-page"), ("slow-image-page", "/delayed.png")] {
            let page = server.url.appendingPathComponent(path)
            let fetching = Task { await store.quickLinkImage(for: page) }
            try await server.waitForRequest(requestPath)
            _ = store.storePageImage(try redPNG(), for: page, sourceURL: URL(string: "data:image/png;base64,live-\(path)")!)
            #expect(!isBlue(try #require(await fetching.value)))
            #expect(!isBlue(try #require(FaviconStore(directory: directory).cachedImage(for: page))))
        }
    }

    private func redPNG() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) } }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func isBlue(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else { return false }
        return color.blueComponent > color.redComponent
    }
}

private struct IconPageServer {
    enum Failure: Error { case startup, timeout }
    let process: Process
    let url: URL

    init() async throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-u", "-c", Self.source]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { process.terminate(); throw Failure.startup }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var bytes: [UInt8] = []
        while ProcessInfo.processInfo.systemUptime < deadline {
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 { if byte == 10 { break }; bytes.append(byte) }
            else if count < 0, errno == EAGAIN || errno == EINTR { try await Task.sleep(for: .milliseconds(10)) }
            else { break }
        }
        guard let text = String(bytes: bytes, encoding: .utf8), let port = Int(text),
              let url = URL(string: "http://127.0.0.1:\(port)") else { process.terminate(); throw Failure.startup }
        self.process = process
        self.url = url
    }
    func close() { if process.isRunning { process.terminate() } }
    func counts() async throws -> [String: Int] {
        let (data, _) = try await URLSession.shared.data(from: url.appendingPathComponent("counts"))
        return try JSONDecoder().decode([String: Int].self, from: data)
    }
    func waitForRequest(_ path: String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if try await counts()[path, default: 0] > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure.timeout
    }
    private static let source = #"""
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    import json, struct, time, zlib
    counts = {}
    def chunk(kind, data): return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', 1, 1, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b'\x00\x00\x00\xff\xff')) + chunk(b'IEND', b'')
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            path = self.path.split('?')[0]
            counts[path] = counts.get(path, 0) + 1
            if path == '/shortcut':
                self.send_response(301); self.send_header('Location', '/hub/index.html'); self.end_headers(); return
            if path in ['/slow-page', '/delayed.png']: time.sleep(.5)
            content_type = 'text/html; charset=utf-8'
            if path == '/counts': body = json.dumps(counts).encode(); content_type = 'application/json'
            elif path.endswith('.png'): body = png; content_type = 'image/png'
            elif path in ['/favicon.ico', '/no-icon']: body = b'<html><head><title>No icon</title></head><body>Not an image</body></html>'
            elif path == '/slow-image-page': body = b'<html><head><link rel="icon" href="/delayed.png"></head></html>'
            else:
                body = b'<html><head><base href="/assets/"><link rel="shortcut icon" href="blue.png"></head><body>'
                if path == '/large-body': body += b'x' * 700000
                body += b'</body></html>'
            self.send_response(200); self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body))); self.send_header('Cache-Control', 'no-store'); self.end_headers()
            try: self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError): pass
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
    """#
}
