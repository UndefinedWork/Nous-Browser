import Foundation

nonisolated struct LibraryBookmark: Codable, Identifiable, Equatable, Sendable {
    var url: URL
    var title: String
    var created: Date
    /// Last add, rename or removal; the newest change wins across Macs.
    var modified: Date
    var removed = false

    var id: String { Self.key(for: url) }

    static func key(for url: URL) -> String {
        (BrowserHistoryStore.canonicalURL(for: url) ?? url).absoluteString
    }

    /// Every Mac's file merged: per page, its most recent change.
    static func merge(_ lists: [[LibraryBookmark]]) -> [String: LibraryBookmark] {
        var result: [String: LibraryBookmark] = [:]
        for bookmark in lists.joined() {
            if let existing = result[bookmark.id], existing.modified >= bookmark.modified { continue }
            result[bookmark.id] = bookmark
        }
        return result
    }
}

/// Bookmarks live with the Library (iCloud Drive when on). Each Mac writes
/// its own merged copy; removals are kept as tombstones so they sync too.
extension LibraryStore {
    var bookmarks: [LibraryBookmark] {
        bookmarkRecords.values.filter { !$0.removed }.sorted { $0.created > $1.created }
    }

    func isBookmarked(_ url: URL?) -> Bool {
        guard let url, BrowserHistoryStore.canonicalURL(for: url) != nil else { return false }
        return bookmarkRecords[LibraryBookmark.key(for: url)]?.removed == false
    }

    func bookmarks(matching query: String, limit: Int) -> [LibraryBookmark] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return [] }
        return Array(bookmarks.filter { bookmark in
            let haystack = (bookmark.title + " " + bookmark.url.absoluteString).lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }.prefix(limit))
    }

    /// Returns whether the page is bookmarked afterwards.
    @discardableResult
    func toggleBookmark(url: URL, title: String) -> Bool {
        guard BrowserHistoryStore.canonicalURL(for: url) != nil else { return false }
        let key = LibraryBookmark.key(for: url)
        let now = Date()
        if var existing = bookmarkRecords[key], !existing.removed {
            existing.removed = true
            existing.modified = now
            bookmarkRecords[key] = existing
        } else {
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            bookmarkRecords[key] = LibraryBookmark(url: url, title: name.isEmpty ? (url.host() ?? url.absoluteString) : name,
                                                   created: now, modified: now)
        }
        saveBookmarks()
        return bookmarkRecords[key]?.removed == false
    }

    func removeBookmark(_ id: String) {
        guard var existing = bookmarkRecords[id], !existing.removed else { return }
        existing.removed = true
        existing.modified = Date()
        bookmarkRecords[id] = existing
        saveBookmarks()
    }

    func renameBookmark(_ id: String, to title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var existing = bookmarkRecords[id], !name.isEmpty, existing.title != name else { return }
        existing.title = name
        existing.modified = Date()
        bookmarkRecords[id] = existing
        saveBookmarks()
    }
}
