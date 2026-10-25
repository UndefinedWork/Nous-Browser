import Darwin
import Foundation
import Observation

nonisolated enum BrowserSearchEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case google, bing, duckDuckGo, baidu

    var id: Self { self }
    var title: String {
        let key = switch self {
        case .google: "Google"
        case .bing: "Bing"
        case .duckDuckGo: "DuckDuckGo"
        case .baidu: "Baidu"
        }
        return L10n.string(key)
    }

    func searchURL(query: String) -> URL {
        let endpoint: String
        let parameter: String
        switch self {
        case .google: (endpoint, parameter) = ("https://www.google.com/search", "q")
        case .bing: (endpoint, parameter) = ("https://www.bing.com/search", "q")
        case .duckDuckGo: (endpoint, parameter) = ("https://duckduckgo.com/", "q")
        case .baidu: (endpoint, parameter) = ("https://www.baidu.com/s", "wd")
        }
        var components = URLComponents(string: endpoint)!
        components.queryItems = [URLQueryItem(name: parameter, value: query)]
        // Search endpoints decode form-style queries, where an unescaped +
        // would otherwise turn a literal plus (for example C++) into a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}

nonisolated struct BrowserQuickLink: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var url: URL

    init(id: UUID = UUID(), title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }
}

nonisolated enum BrowserPreferencesError: Error, Equatable, LocalizedError {
    case emptyTitle, invalidAddress, linkNotFound

    var errorDescription: String? {
        switch self {
        case .emptyTitle: L10n.string("Enter a name for the quick link.")
        case .invalidAddress: L10n.string("Enter a valid HTTP or HTTPS address.")
        case .linkNotFound: L10n.string("The quick link is no longer available.")
        }
    }
}

@MainActor
@Observable
final class BrowserPreferences {
    private(set) var searchEngine: BrowserSearchEngine
    private(set) var quickLinks: [BrowserQuickLink]
    @ObservationIgnored private let defaults: UserDefaults

    private static let searchEngineKey = "browser.searchEngine"
    private static let quickLinksKey = "browser.quickLinks"

    nonisolated static var defaultQuickLinks: [BrowserQuickLink] {
        [
            BrowserQuickLink(id: UUID(uuidString: "3A77327B-F47A-4BA5-9A36-9670FD1B7101")!, title: "Apple", url: URL(string: "https://www.apple.com")!),
            BrowserQuickLink(id: UUID(uuidString: "3A77327B-F47A-4BA5-9A36-9670FD1B7102")!, title: "Google", url: URL(string: "https://www.google.com")!),
            BrowserQuickLink(id: UUID(uuidString: "3A77327B-F47A-4BA5-9A36-9670FD1B7103")!, title: L10n.string("Wikipedia"), url: URL(string: "https://www.wikipedia.org")!),
            BrowserQuickLink(id: UUID(uuidString: "3A77327B-F47A-4BA5-9A36-9670FD1B7104")!, title: "ChatGPT", url: URL(string: "https://chatgpt.com")!)
        ]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        searchEngine = defaults.string(forKey: Self.searchEngineKey).flatMap(BrowserSearchEngine.init(rawValue:)) ?? .google
        if let data = defaults.data(forKey: Self.quickLinksKey),
           let saved = try? JSONDecoder().decode([BrowserQuickLink].self, from: data) {
            var seen = Set<UUID>()
            let valid = saved.compactMap { link -> BrowserQuickLink? in
                guard let entry = try? Self.validatedLink(id: link.id, title: link.title, address: link.url.absoluteString),
                      seen.insert(link.id).inserted else { return nil }
                return entry
            }
            quickLinks = saved.isEmpty || !valid.isEmpty ? valid : Self.defaultQuickLinks
        } else {
            quickLinks = Self.defaultQuickLinks
        }
    }

    func selectSearchEngine(_ engine: BrowserSearchEngine) {
        searchEngine = engine
        defaults.set(engine.rawValue, forKey: Self.searchEngineKey)
    }

    @discardableResult
    func addQuickLink(title: String, address: String) throws -> BrowserQuickLink {
        let link = try Self.validatedLink(id: UUID(), title: title, address: address)
        quickLinks.append(link)
        saveQuickLinks()
        return link
    }

    func updateQuickLink(id: UUID, title: String, address: String) throws {
        guard let index = quickLinks.firstIndex(where: { $0.id == id }) else { throw BrowserPreferencesError.linkNotFound }
        let link = try Self.validatedLink(id: id, title: title, address: address)
        quickLinks[index] = link
        saveQuickLinks()
    }

    func removeQuickLink(id: UUID) {
        guard let index = quickLinks.firstIndex(where: { $0.id == id }) else { return }
        quickLinks.remove(at: index)
        saveQuickLinks()
    }

    func moveQuickLink(id: UUID, offset: Int) {
        guard offset == -1 || offset == 1,
              let index = quickLinks.firstIndex(where: { $0.id == id }),
              quickLinks.indices.contains(index + offset) else { return }
        quickLinks.swapAt(index, index + offset)
        saveQuickLinks()
    }

    func restoreDefaultQuickLinks() {
        quickLinks = Self.defaultQuickLinks
        saveQuickLinks()
    }

    private func saveQuickLinks() {
        guard let data = try? JSONEncoder().encode(quickLinks) else { return }
        defaults.set(data, forKey: Self.quickLinksKey)
    }

    private static func validatedLink(id: UUID, title: String, address: String) throws -> BrowserQuickLink {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw BrowserPreferencesError.emptyTitle }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !address.contains("\\"),
              !address.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw BrowserPreferencesError.invalidAddress
        }
        let candidate: String
        if address.lowercased().hasPrefix("https://") || address.lowercased().hasPrefix("http://") {
            candidate = address
        } else {
            guard !address.contains("://") else { throw BrowserPreferencesError.invalidAddress }
            if address.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil {
                // A bare host:port is allowed; arbitrary URL schemes are not.
                let authority = address.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? address
                let hostAndPort = authority.split(separator: ":", omittingEmptySubsequences: false)
                guard hostAndPort.count == 2,
                      hostAndPort[0].contains(".") || hostAndPort[0].lowercased() == "localhost",
                      !hostAndPort[1].isEmpty, hostAndPort[1].allSatisfy(\.isNumber) else {
                    throw BrowserPreferencesError.invalidAddress
                }
            }
            candidate = "https://" + address
        }
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil,
              let url = components.url, let host = url.host, Self.isValidHost(host),
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw BrowserPreferencesError.invalidAddress
        }
        components.scheme = scheme
        guard let normalized = components.url else { throw BrowserPreferencesError.invalidAddress }
        return BrowserQuickLink(id: id, title: title, url: normalized)
    }

    private static func isValidHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.contains(":") {
            var address = in6_addr()
            return host.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
        }
        if host.split(separator: ".", omittingEmptySubsequences: false).count == 4,
           host.allSatisfy({ $0.isNumber || $0 == "." }) {
            var address = in_addr()
            return host.withCString { inet_pton(AF_INET, $0, &address) == 1 }
        }
        let domain = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !domain.isEmpty, domain.utf8.count <= 253 else { return false }
        return domain.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
        }
    }
}
