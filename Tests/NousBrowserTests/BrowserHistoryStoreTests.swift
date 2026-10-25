import Foundation
import Testing
@testable import NousBrowser

@Suite("Local browsing history")
@MainActor
struct BrowserHistoryStoreTests {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.json")
    }

    @Test func canonicalizationStripsCredentialsFragmentsAndDefaultPortsWhilePreservingQueries() throws {
        let input = try #require(URL(string: "https://person:secret@EXAMPLE.com:443/watch?v=one#section"))
        let result = try #require(BrowserHistoryStore.canonicalURL(for: input))
        #expect(result.absoluteString == "https://example.com/watch?v=one")
        #expect(BrowserHistoryStore.canonicalURL(for: URL(string: "https://example.com")!)?.absoluteString == "https://example.com/")
        #expect(BrowserHistoryStore.canonicalURL(for: URL(string: "http://localhost:8765/test")!)?.port == 8765)
        for address in ["file:///tmp/test.html", "about:blank", "data:text/plain,test", "javascript:alert(1)", "https://999.999.999.999/"] {
            #expect(BrowserHistoryStore.canonicalURL(for: URL(string: address)!) == nil)
        }
    }

    @Test func secretQueriesAreNotRecordedOrSeeded() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = BrowserHistoryStore(fileURL: file)
        for key in ["code", "access_token", "ID_TOKEN", "token", "password", "client-secret", "api_key", "csrfToken", "SAMLResponse", "session_id", "otp"] {
            let url = try #require(URL(string: "https://example.test/callback?\(key)=synthetic-only"))
            #expect(BrowserHistoryStore.canonicalURL(for: url) == nil)
            store.recordVisit(url: url, title: "Synthetic authentication callback")
            store.rememberExistingPage(url: url, title: "Synthetic callback seed")
        }
        #expect(store.entries.isEmpty)
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func countsSeparateVisitsAndDeduplicatesImmediateNavigation() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = BrowserHistoryStore(fileURL: file)
        let url = URL(string: "https://example.test/page")!
        let start = Date(timeIntervalSince1970: 1_000)
        store.recordVisit(url: url, title: "Initial", at: start)
        store.recordVisit(url: URL(string: url.absoluteString + "#next")!, title: "Updated", at: start.addingTimeInterval(29))
        #expect(store.entries.count == 1)
        #expect(store.entries[0].visitCount == 1)
        #expect(store.entries[0].title == "Updated")
        #expect(store.entries[0].lastVisited == start.addingTimeInterval(29))
        store.recordVisit(url: url, title: "Later", at: start.addingTimeInterval(59))
        #expect(store.entries[0].visitCount == 2)
        store.recordVisit(url: URL(string: "https://example.test/page?v=other")!, title: "Other ID", at: start)
        #expect(store.entries.count == 2)
        #expect(store.entries.allSatisfy { $0.id == $0.url.absoluteString })
        store.flush()
    }

    @Test func seedingAndTitleUpdatesNeverInflateFrequencyOrRecency() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = BrowserHistoryStore(fileURL: file)
        let url = URL(string: "https://example.test/page")!
        store.rememberExistingPage(url: url, title: "Existing")
        let original = try #require(store.entries.first)
        store.rememberExistingPage(url: url, title: "Repeated seed")
        #expect(store.entries == [original])
        store.updateTitle(url: url, title: "  Async title  ")
        #expect(store.entries[0].title == "Async title")
        #expect(store.entries[0].visitCount == 1)
        #expect(store.entries[0].lastVisited == original.lastVisited)
        store.updateTitle(url: url, title: " \n ")
        store.updateTitle(url: URL(string: "https://unknown.test/")!, title: "Not visited")
        #expect(store.entries.count == 1)
        #expect(store.entries[0].title == "Async title")
        store.flush()
    }

    @Test func matchesFoldLanguageAndDomainDotsAndRequireEveryKeyword() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = BrowserHistoryStore(fileURL: file)
        store.recordVisit(url: URL(string: "https://x.com/topic")!, title: "ＣＡＦÉ 浏览器 Notes")
        store.recordVisit(url: URL(string: "https://example.test/%E5%8A%A8%E7%94%BB")!, title: "Reference")
        #expect(store.matches(query: "cafe 浏览器").first?.url.host == "x.com")
        #expect(store.matches(query: " ＣＡＦＥ   notes ").count == 1)
        #expect(store.matches(query: "x。com").first?.url.host == "x.com")
        #expect(store.matches(query: "xcom").first?.url.host == "x.com")
        #expect(store.matches(query: "动画").first?.title == "Reference")
        #expect(store.matches(query: "cafe missing").isEmpty)
        #expect(store.matches(query: " ").isEmpty)
        #expect(store.matches(query: "cafe", limit: 0).isEmpty)
        store.flush()
    }

    @Test func relevanceThenFrequencyThenRecencyAndStableURLDetermineOrder() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = BrowserHistoryStore(fileURL: file)
        let start = Date(timeIntervalSince1970: 2_000)
        let host = URL(string: "https://notes.test/")!
        let frequent = URL(string: "https://example.test/frequent")!
        let newer = URL(string: "https://example.test/newer")!
        store.recordVisit(url: host, title: "A host match", at: start)
        store.recordVisit(url: frequent, title: "Notes page", at: start)
        store.recordVisit(url: frequent, title: "Notes page", at: start.addingTimeInterval(31))
        store.recordVisit(url: newer, title: "Notes page", at: start.addingTimeInterval(100))
        #expect(store.matches(query: "notes").map(\.url) == [host, frequent, newer])
        let tieA = URL(string: "https://ties.test/a")!
        let tieB = URL(string: "https://ties.test/b")!
        store.recordVisit(url: tieB, title: "Tie", at: start)
        store.recordVisit(url: tieA, title: "Tie", at: start)
        #expect(store.matches(query: "tie").map(\.url) == [tieA, tieB])
        #expect(store.matches(query: "notes", limit: 1).map(\.url) == [host])
        store.flush()
    }

    @Test func flushPersistsPrivateHistoryWithoutWaitingForDebounce() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = BrowserHistoryStore(fileURL: file)
        store.recordVisit(url: URL(string: "https://example.test/watch?v=one")!, title: "Synthetic only")
        store.flush()
        let restored = BrowserHistoryStore(fileURL: file)
        #expect(restored.entries == store.entries)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        let raw = try String(contentsOf: file, encoding: .utf8)
        #expect(!raw.contains("password"))
    }

    @Test func corruptedHistoryIsLeftUntouchedAndPreservedBeforeAWrite() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let corrupted = Data("{synthetic broken history".utf8)
        try corrupted.write(to: file)
        let store = BrowserHistoryStore(fileURL: file)
        #expect(store.entries.isEmpty)
        #expect(try Data(contentsOf: file) == corrupted)
        store.recordVisit(url: URL(string: "https://example.test/")!, title: "Synthetic")
        store.flush()
        let files = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let backup = try #require(files.first { $0.lastPathComponent.contains("preserved-") })
        #expect(try Data(contentsOf: backup) == corrupted)
        let permissions = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(BrowserHistoryStore(fileURL: file).entries == store.entries)
    }

    @Test func retainsTheTwoThousandMostRecentPages() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 5_000)
        let saved = (0..<2_002).map { index in
            BrowserHistoryEntry(url: URL(string: "https://example.test/\(index)")!, title: "Synthetic \(index)",
                                visitCount: index == 0 ? 1_000 : 1, lastVisited: start.addingTimeInterval(Double(index)))
        }
        try JSONEncoder().encode(saved).write(to: file)
        let store = BrowserHistoryStore(fileURL: file)
        #expect(store.entries.count == 2_000)
        #expect(!store.entries.contains { $0.url.lastPathComponent == "0" || $0.url.lastPathComponent == "1" })
        store.recordVisit(url: URL(string: "https://example.test/new")!, title: "New", at: start.addingTimeInterval(3_000))
        #expect(store.entries.count == 2_000)
        #expect(store.entries.first?.title == "New")
        #expect(!store.entries.contains { $0.url.lastPathComponent == "2" })
        store.flush()
    }
}
