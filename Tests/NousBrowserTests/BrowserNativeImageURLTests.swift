import Foundation
import Testing
@testable import NousBrowser

@Suite("Native image URLs remain separate from external navigation")
struct BrowserNativeImageURLTests {
    @Test @MainActor func temporaryImageSessionsRestoreBlankWithoutChangingTheLiveTab() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessionURL = directory.appendingPathComponent("session.json")
        let dataURL = try #require(URL(string: "data:image/png;base64," + String(repeating: "A", count: 1_048_576)))
        let blobURL = try #require(URL(string: "blob:https://images.example.test/temporary-image"))
        let website = try #require(URL(string: "https://docs.example.test/work?document=42"))
        let entries = [dataURL, blobURL, website].enumerated().map {
            BrowserSession.Tab(id: UUID(), title: $0.offset == 0 ? $0.element.absoluteString : "Image \($0.offset)",
                               url: $0.element, isPinned: $0.offset == 1)
        }
        let session = BrowserSession(tabs: entries, selectedTabID: entries[0].id, isSidebarVisible: true,
                                     sidebarWidth: 300, isSidebarCompact: true)
        try JSONEncoder().encode(session).write(to: sessionURL)
        let model = BrowserModel(sessionURL: sessionURL, loadSelectedTab: false)
        defer {
            model.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        model.persistSession()
        let savedBytes = try Data(contentsOf: sessionURL)
        let saved = try JSONDecoder().decode(BrowserSession.self, from: savedBytes)
        #expect(savedBytes.count < 4_096)
        #expect(saved.tabs.first(where: { $0.id == entries[0].id })?.url == nil)
        #expect(saved.tabs.first(where: { $0.id == entries[0].id })?.title == L10n.string("New Tab"))
        #expect(saved.tabs.first(where: { $0.id == entries[1].id })?.url == nil)
        #expect(saved.tabs.first(where: { $0.id == entries[2].id })?.url == website)
        #expect(saved.tabs.map(\.id) == model.tabs.filter { !$0.isPinned }.map(\.id))
        #expect(saved.selectedTabID == entries[0].id)
        #expect(saved.isSidebarCompact && saved.sidebarWidth == 300)
        #expect(model.tabs.first(where: { $0.id == entries[0].id })?.url == dataURL)
        // A pinned blob page becomes a blank pin: its blob died with the old session.
        #expect(model.tabs.first(where: { $0.id == entries[1].id })?.url == nil)
        let restored = BrowserModel(sessionURL: sessionURL, loadSelectedTab: false)
        defer { restored.shutdown() }
        #expect(restored.tabs.first(where: { $0.id == entries[0].id })?.hasWebContent == false)
        #expect(restored.tabs.first(where: { $0.id == entries[1].id })?.hasWebContent == false)
        #expect(restored.tabs.first(where: { $0.id == entries[2].id })?.url == website)
    }

    @Test(arguments: [
        "https://images.example.test/image.png",
        "http://localhost:8080/image.svg",
        "data:image/png;base64,aGVsbG8=",
        "data:image/svg+xml,%3Csvg/%3E",
        "blob:https://images.example.test/7adc62d4-365c-40c5-a5f6-649af81e9052",
        "blob:null/7adc62d4-365c-40c5-a5f6-649af81e9052"
    ])
    func acceptsExplicitNativeImageNavigation(_ address: String) throws {
        let url = try #require(URL(string: address))
        #expect(BrowserNativeImageURL.allows(url))
        if ["blob", "data"].contains(url.scheme ?? "") {
            #expect(!BrowserModel.canOpenExternalURL(url))
        }
    }

    @Test(arguments: [
        "data:text/html,%3Cscript%3Ealert(1)%3C/script%3E", "data:text/plain,hello",
        "data:;base64,aGVsbG8=", "data:image/png", "data:image/,abc",
        "blob:file:///etc/passwd", "blob:chrome://settings/token", "blob:https://example.test",
        "blob:null/", "blob:https://username:password@example.test/token",
        "javascript:alert(1)", "file:///tmp/image.png", "chrome://settings", "custom:open", "https:"
    ])
    func rejectsNonimageActiveOrPrivilegedURLs(_ address: String) throws {
        let url = try #require(URL(string: address))
        #expect(!BrowserNativeImageURL.allows(url))
    }
}
