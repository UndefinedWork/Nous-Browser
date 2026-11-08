import Foundation

nonisolated enum BrowserAddressPrimarySuggestion {
    /// Keep the primary row aligned with address submission. Explicit schemes
    /// use the navigation policy so internal diagnostics cannot acquire a
    /// separate, broader allowlist just for their display label.
    static func navigationURL(for input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("://") { return BrowserModel.normalizeAddress(text) }
        return BrowserAddressInput.websiteURL(for: text)
    }
}

@MainActor
enum BrowserAddressSuggestion {
    case openTab(BrowserTab)
    case visitedPage(BrowserHistoryEntry)
    case bookmark(LibraryBookmark)

    var id: String {
        switch self {
        case .openTab(let tab): "tab-" + tab.id.uuidString
        case .visitedPage(let entry): "history-" + entry.id
        case .bookmark(let bookmark): "bookmark-" + bookmark.id
        }
    }

    var title: String {
        switch self {
        case .openTab(let tab): tab.displayTitle
        case .visitedPage(let entry): entry.title
        case .bookmark(let bookmark): bookmark.title
        }
    }

    var url: URL {
        switch self {
        // Only tabs with a URL are included in addressSuggestions.
        case .openTab(let tab): tab.url!
        case .visitedPage(let entry): entry.url
        case .bookmark(let bookmark): bookmark.url
        }
    }
}

extension BrowserController {
    var addressSuggestions: [BrowserAddressSuggestion] {
        let tokens = Self.matchingText(addressText).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        var openTabs: [BrowserTab] = []
        var seenURLs = Set<String>()
        for tab in model.tabs {
            guard let url = tab.url else { continue }
            let searchable = Self.matchingText(tab.displayTitle + " " + url.absoluteString)
            let key = BrowserHistoryStore.canonicalURL(for: url)?.absoluteString ?? url.absoluteString
            guard tokens.allSatisfy({ searchable.contains($0) }), seenURLs.insert(key).inserted else { continue }
            openTabs.append(tab)
            if openTabs.count == 4 { break }
        }
        let openURLs = Set(openTabs.compactMap { tab in
            tab.url.flatMap(BrowserHistoryStore.canonicalURL(for:))?.absoluteString
        })
        var results = openTabs.map(BrowserAddressSuggestion.openTab)
        var shown = openURLs
        // Bookmarks rank above plain history.
        for bookmark in LibraryStore.shared.bookmarks(matching: Self.matchingText(addressText), limit: 3)
            where shown.insert(bookmark.id).inserted {
            results.append(.bookmark(bookmark))
            if results.count == 6 { return results }
        }
        for entry in history.matches(query: addressText, limit: 6) where !shown.contains(entry.id) {
            results.append(.visitedPage(entry))
            if results.count == 6 { break }
        }
        return results
    }

    func activateSuggestion(_ suggestion: BrowserAddressSuggestion) {
        if case .openTab(let tab) = suggestion, model.tabs.contains(where: { $0.id == tab.id }) {
            model.selectTab(tab.id)
            dismissAddress()
        } else {
            addressText = suggestion.url.absoluteString
            submitAddress()
        }
    }

    private static func matchingText(_ value: String) -> String {
        (value.removingPercentEncoding ?? value)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "。", with: ".")
            .replacingOccurrences(of: "｡", with: ".")
    }
}
