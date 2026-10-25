import Darwin
import Foundation
import Observation

nonisolated struct BrowserHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let url: URL
    var title: String
    var visitCount: Int
    var lastVisited: Date

    var id: String { url.absoluteString }
}

/// Local navigation metadata only. Website sessions and credentials remain in
/// their existing stores and are never read or copied into this file.
@MainActor
@Observable
final class BrowserHistoryStore {
    private(set) var entries: [BrowserHistoryEntry] = []
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var unreadableOriginal: Data?

    private static let maximumEntries = 2_000
    private static let repeatInterval: TimeInterval = 30

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nous Browser", isDirectory: true)
            .appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: self.fileURL) else { return }
        guard let saved = try? JSONDecoder().decode([BrowserHistoryEntry].self, from: data) else {
            unreadableOriginal = data
            return
        }
        var unique: [String: BrowserHistoryEntry] = [:]
        for entry in saved {
            guard let url = Self.canonicalURL(for: entry.url), entry.visitCount > 0,
                  entry.lastVisited.timeIntervalSinceReferenceDate.isFinite else { continue }
            let clean = BrowserHistoryEntry(url: url, title: Self.title(entry.title, fallbackURL: url),
                                            visitCount: entry.visitCount, lastVisited: entry.lastVisited)
            if let previous = unique[clean.id] {
                let recent = clean.lastVisited > previous.lastVisited ? clean : previous
                unique[clean.id] = BrowserHistoryEntry(url: url, title: recent.title,
                                                       visitCount: max(clean.visitCount, previous.visitCount),
                                                       lastVisited: recent.lastVisited)
            } else {
                unique[clean.id] = clean
            }
        }
        entries = Array(unique.values.sorted(by: Self.moreRecent).prefix(Self.maximumEntries))
        isDirty = entries != saved
    }

    /// Shared by navigation recording and suggestion deduplication. Preserve
    /// ordinary queries, since different video/article IDs are different pages.
    nonisolated static func canonicalURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, isValidHost(host),
              components.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        if let items = components.queryItems, items.contains(where: { isSecretQueryName($0.name) }) {
            return nil
        }
        components.scheme = scheme
        components.host = host.lowercased()
        components.user = nil
        components.password = nil
        components.fragment = nil
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }

    func recordVisit(url: URL, title: String, at date: Date = Date()) {
        guard let url = Self.canonicalURL(for: url), date.timeIntervalSinceReferenceDate.isFinite else { return }
        if let index = entries.firstIndex(where: { $0.id == url.absoluteString }) {
            if date.timeIntervalSince(entries[index].lastVisited) >= Self.repeatInterval,
               entries[index].visitCount < Int.max {
                entries[index].visitCount += 1
            }
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty { entries[index].title = trimmedTitle }
            entries[index].lastVisited = max(entries[index].lastVisited, date)
        } else {
            entries.append(.init(url: url, title: Self.title(title, fallbackURL: url),
                                 visitCount: 1, lastVisited: date))
        }
        retainRecentEntries()
        scheduleSave()
    }

    /// Seeds existing/restored pages once, without treating an app launch or
    /// repeated suggestion query as a fresh visit.
    func rememberExistingPage(url: URL, title: String) {
        guard let canonical = Self.canonicalURL(for: url),
              !entries.contains(where: { $0.id == canonical.absoluteString }) else { return }
        recordVisit(url: canonical, title: title)
    }

    /// Titles can arrive after navigation completes; this must not extend the
    /// repeat-navigation window or change the page's visit frequency/recency.
    func updateTitle(url: URL, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let canonical = Self.canonicalURL(for: url),
              let index = entries.firstIndex(where: { $0.id == canonical.absoluteString }),
              entries[index].title != title else { return }
        entries[index].title = title
        scheduleSave()
    }

    func matches(query: String, limit: Int = 6) -> [BrowserHistoryEntry] {
        let folded = Self.fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = folded.split(whereSeparator: \.isWhitespace).map(String.init)
        guard limit > 0, !tokens.isEmpty else { return [] }
        let normalizedQuery = tokens.joined(separator: " ")
        return entries.compactMap { entry -> (BrowserHistoryEntry, Int)? in
            guard let score = Self.relevance(of: entry, tokens: tokens, query: normalizedQuery) else { return nil }
            return (entry, score)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.visitCount != rhs.0.visitCount { return lhs.0.visitCount > rhs.0.visitCount }
            if lhs.0.lastVisited != rhs.0.lastVisited { return lhs.0.lastVisited > rhs.0.lastVisited }
            return lhs.0.id < rhs.0.id
        }.prefix(limit).map(\.0)
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty else { return }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            if let unreadableOriginal {
                let backup = fileURL.deletingPathExtension()
                    .appendingPathExtension("preserved-" + UUID().uuidString + ".json")
                try unreadableOriginal.write(to: backup, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                self.unreadableOriginal = nil
            }
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            isDirty = false
        } catch {
            // Do not include visited addresses or page titles in logs.
            NSLog("Nous Browser: Could not save browsing history.")
        }
    }

    private func retainRecentEntries() {
        entries.sort(by: Self.moreRecent)
        if entries.count > Self.maximumEntries { entries.removeLast(entries.count - Self.maximumEntries) }
    }

    private func scheduleSave() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    nonisolated private static func moreRecent(_ lhs: BrowserHistoryEntry, _ rhs: BrowserHistoryEntry) -> Bool {
        if lhs.lastVisited != rhs.lastVisited { return lhs.lastVisited > rhs.lastVisited }
        return lhs.id < rhs.id
    }

    nonisolated private static func title(_ title: String, fallbackURL: URL) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackURL.host ?? fallbackURL.absoluteString : trimmed
    }

    nonisolated private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "。", with: ".")
            .replacingOccurrences(of: "｡", with: ".")
            .replacingOccurrences(of: "．", with: ".")
    }

    nonisolated private static func relevance(of entry: BrowserHistoryEntry, tokens: [String], query: String) -> Int? {
        let host = fold(entry.url.host ?? "")
        let hostWithoutWWW = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let compactHost = hostWithoutWWW.replacingOccurrences(of: ".", with: "")
        let title = fold(entry.title)
        let address = fold(entry.url.absoluteString.removingPercentEncoding ?? entry.url.absoluteString)
        var total = 0
        for token in tokens {
            let compactToken = token.replacingOccurrences(of: ".", with: "")
            let score: Int
            if host == token || hostWithoutWWW == token { score = 1_000 }
            else if host.hasPrefix(token) || hostWithoutWWW.hasPrefix(token) { score = 700 }
            else if !compactToken.isEmpty && compactHost.hasPrefix(compactToken) { score = 650 }
            else if title == token { score = 500 }
            else if title.hasPrefix(token) { score = 350 }
            else if title.contains(token) { score = 250 }
            else if host.contains(token) || (!compactToken.isEmpty && compactHost.contains(compactToken)) { score = 200 }
            else if address.contains(token) { score = 100 }
            else { return nil }
            total += score
        }
        if host == query || hostWithoutWWW == query { total += 2_000 }
        else if title == query { total += 500 }
        return total
    }

    nonisolated private static func isSecretQueryName(_ name: String) -> Bool {
        let key = fold(name).filter { $0.isLetter || $0.isNumber }
        let secretNames: Set<String> = [
            "code", "authcode", "authorizationcode", "token", "accesstoken", "idtoken", "refreshtoken",
            "password", "passwd", "pwd", "passcode", "secret", "clientsecret", "apikey", "auth", "authorization",
            "assertion", "samlresponse", "samlrequest", "ticket", "credential", "credentials",
            "session", "sessionid", "sid", "jwt", "otp", "onetimecode", "verificationcode", "oauthverifier",
            "signature", "sig"
        ]
        return secretNames.contains(key) || key.hasSuffix("token") || key.contains("password")
            || key.hasSuffix("secret") || key.hasSuffix("signature")
    }

    nonisolated private static func isValidHost(_ host: String) -> Bool {
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
