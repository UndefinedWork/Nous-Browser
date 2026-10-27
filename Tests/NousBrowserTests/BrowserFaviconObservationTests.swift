import AppKit
import Foundation
import Testing
import WebKit
@testable import NousBrowser

@Suite("Live page favicon declarations", .serialized)
@MainActor
struct BrowserFaviconObservationTests {
    @Test func validatesBridgePayloadAndInstallsOnlyOnceInTheMainFrame() throws {
        let configuration = WKWebViewConfiguration()
        BrowserFaviconObservation.install(in: configuration)
        BrowserFaviconObservation.install(in: configuration)
        let scripts = configuration.userContentController.userScripts
        #expect(scripts.count == 1)
        #expect(scripts[0].isForMainFrameOnly)
        #expect(scripts[0].injectionTime == .atDocumentStart)
        let valid: [String: Any] = ["pageURL": "https://example.test/document", "documentID": "fixture", "revision": 1,
                                  "candidates": ["data:image/png;base64,AA=="]]
        #expect(BrowserFaviconObservation.snapshot(from: valid)?.candidates.count == 1)
        for replacement: [String: Any] in [
            ["pageURL": "file:///private/file"], ["pageURL": "https://user:secret@example.test/"],
            ["revision": 0], ["documentID": ""], ["candidates": ["javascript:alert(1)"]],
            ["candidates": Array(repeating: "https://example.test/icon.png", count: 9)],
            ["candidates": ["data:image/png;base64," + String(repeating: "a", count: 2 * 1024 * 1024)]]
        ] {
            #expect(BrowserFaviconObservation.snapshot(from: valid.merging(replacement) { _, new in new }) == nil)
        }
    }

    @Test func lateDocumentIconChangesReplaceStaticIconsAndRemovalFallsBack() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let red = icon("red"), blue = icon("blue")
        try await fixture.load("<link id='site' rel='icon' type='image/svg+xml' sizes='any' href='\(red)'>")
        #expect(fixture.latest?.candidates.first?.absoluteString == red)
        try await fixture.run("""
        setTimeout(() => {
            const link = document.createElement('link'); link.id='document'; link.rel='icon';
            link.href=\(json(blue)); document.head.append(link);
        }, 50); true;
        """)
        try await fixture.wait { fixture.latest?.candidates.first?.absoluteString == blue }
        #expect(fixture.latest?.candidates.map(\.absoluteString) == [blue, red])
        let before = fixture.snapshots.count
        try await fixture.run("document.getElementById('document').href = \(json(red)); true;")
        try await fixture.wait { fixture.snapshots.count > before && fixture.latest?.candidates.map(\.absoluteString) == [red] }
        try await fixture.run("document.getElementById('document').remove(); document.getElementById('site').remove(); true;")
        try await fixture.wait { fixture.latest?.candidates.isEmpty == true }
        #expect(try await fixture.view.evaluateJavaScript("typeof globalThis.__nousFaviconObservation") as? String == "undefined")
    }

    @Test func mediaRelBaseAndHeadChangesAreObservedWithoutBodyMutations() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let red = icon("red"), blue = icon("blue")
        try await fixture.load("<base href='https://example.test/a/'><link id='icon' rel='icon' href='icon.png'><link rel='apple-touch-icon' href='\(blue)'><link id='print' rel='icon' href='\(red)' media='print'>")
        #expect(fixture.latest?.candidates.first?.absoluteString == "https://example.test/a/icon.png")
        try await fixture.run("document.querySelector('base').href = 'https://example.test/b/'; true;")
        try await fixture.wait { fixture.latest?.candidates.first?.absoluteString == "https://example.test/b/icon.png" }
        try await fixture.run("document.getElementById('print').media = 'screen'; true;")
        try await fixture.wait { fixture.latest?.candidates.first?.absoluteString == red }
        try await fixture.run("document.getElementById('print').rel = 'stylesheet'; true;")
        try await fixture.wait { fixture.latest?.candidates.first?.absoluteString == "https://example.test/b/icon.png" }
        let count = fixture.snapshots.count
        try await fixture.run("document.body.append(document.createElement('p')); true;")
        try await Task.sleep(for: .milliseconds(120))
        #expect(fixture.snapshots.count == count)
        try await fixture.run("const head=document.createElement('head');head.innerHTML=\(json("<link rel='icon' href='\(blue)'>"));document.head.replaceWith(head);true;")
        try await fixture.wait { fixture.latest?.candidates.map(\.absoluteString) == [blue] }
    }

    @Test func ignoresIframeIconsAndExplicitRefreshTracksSPARoutes() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let red = icon("red"), blue = icon("blue")
        try await fixture.load("<link rel='icon' href='\(red)'>")
        try await fixture.run("const frame=document.createElement('iframe');frame.srcdoc=\(json("<link rel='icon' href='\(blue)'>"));document.body.append(frame);true;")
        try await Task.sleep(for: .milliseconds(120))
        #expect(fixture.latest?.candidates.map(\.absoluteString) == [red])
        try await fixture.run("history.pushState({}, '', '/second#document'); true;")
        fixture.attachment.refresh()
        try await fixture.wait { fixture.latest?.pageURL.path == "/second" }
        #expect(fixture.latest?.pageURL.fragment == "document")
        let previous = try #require(fixture.latest)
        fixture.attachment.refresh()
        try await fixture.wait { (fixture.latest?.revision ?? 0) > previous.revision }
        #expect(!fixture.attachment.isCurrent(previous))
        let refreshed = try #require(fixture.latest)
        #expect(fixture.attachment.isCurrent(refreshed))
    }

    @Test func rasterizesBlobAndEmojiSVGAndRejectsStaleSnapshots() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let starSVG = "<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64'><text x='1' y='54' font-size='56'>⭐</text></svg>"
        let dataURL = "data:image/svg+xml;base64," + Data(starSVG.utf8).base64EncodedString()
        try await fixture.load("<link id='icon' rel='icon' href='\(dataURL)'>")
        let snapshot = try #require(fixture.latest)
        let candidate = try #require(snapshot.candidates.first)
        let rendered = try #require(await fixture.attachment.rasterize(candidate, snapshot: snapshot))
        let bitmap = try #require(NSBitmapImageRep(data: rendered))
        #expect(bitmap.pixelsWide == 64 && bitmap.pixelsHigh == 64)
        var visiblePixels = 0
        for x in 0..<64 { for y in 0..<64 { if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { visiblePixels += 1 } } }
        #expect(visiblePixels > 200)
        try await fixture.run("document.getElementById('icon').href = URL.createObjectURL(new Blob([\(json(starSVG))], {type:'image/svg+xml'})); true;")
        try await fixture.wait { fixture.latest?.candidates.first?.scheme == "blob" }
        let blobSnapshot = try #require(fixture.latest)
        let blobCandidate = try #require(blobSnapshot.candidates.first)
        #expect(await fixture.attachment.rasterize(candidate, snapshot: snapshot) == nil)
        #expect(await fixture.attachment.rasterize(blobCandidate, snapshot: blobSnapshot) != nil)
        fixture.attachment.invalidate()
        #expect(!fixture.attachment.isCurrent(blobSnapshot))
        #expect(await fixture.attachment.rasterize(blobCandidate, snapshot: blobSnapshot) == nil)
    }

    @Test func inheritedControllerRoutesOnlyToItsOwnWebView() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        BrowserFaviconObservation.install(in: configuration)
        let first = Fixture(configuration: configuration), second = Fixture(configuration: configuration)
        defer { first.close(); second.close() }
        let red = icon("red"), blue = icon("blue")
        try await first.load("<link rel='icon' href='\(red)'>")
        try await second.load("<link rel='icon' href='\(blue)'>")
        #expect(first.latest?.candidates.first?.absoluteString == red)
        #expect(second.latest?.candidates.first?.absoluteString == blue)
        first.attachment.invalidate()
        let count = second.snapshots.count
        second.attachment.refresh()
        try await second.wait { second.snapshots.count > count }
        #expect(second.latest?.candidates.first?.absoluteString == blue)
    }

    private func icon(_ color: String) -> String {
        "data:image/svg+xml;base64," + Data("<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='\(color)'/></svg>".utf8).base64EncodedString()
    }

    private func json(_ string: String) -> String {
        String(decoding: try! JSONEncoder().encode(string), as: UTF8.self)
    }

    @MainActor private final class Fixture {
        let view: WKWebView
        var snapshots: [BrowserFaviconObservation.Snapshot] = []
        var attachment: BrowserFaviconObservation.Attachment!
        var latest: BrowserFaviconObservation.Snapshot? { snapshots.last }

        init(configuration: WKWebViewConfiguration? = nil) {
            let config = configuration ?? WKWebViewConfiguration()
            if configuration == nil { config.websiteDataStore = .nonPersistent() }
            BrowserFaviconObservation.install(in: config)
            view = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: config)
            attachment = BrowserFaviconObservation.attach(to: view) { [weak self] in self?.snapshots.append($0) }
        }

        func load(_ head: String) async throws {
            view.loadHTMLString("<!doctype html><html><head><meta charset='utf-8'>\(head)</head><body>Favicon fixture</body></html>",
                                baseURL: URL(string: "https://example.test/document")!)
            try await wait { !view.isLoading && view.url != nil }
            try await wait { !snapshots.isEmpty }
            // The forced publication is asynchronous. Waiting only for a
            // nonempty list can return the initial snapshot and let this
            // requested refresh correctly invalidate it during rasterization.
            let previousCount = snapshots.count
            attachment.refresh()
            try await wait { snapshots.count > previousCount }
        }

        func run(_ source: String) async throws { _ = try await view.evaluateJavaScript(source) }

        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(condition(), "The synthetic favicon fixture did not finish")
        }

        func close() {
            attachment.invalidate()
            view.stopLoading()
        }
    }
}
