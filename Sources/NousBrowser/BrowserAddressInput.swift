import Foundation

/// Recognizes website addresses without changing search text or any URL suffix.
nonisolated enum BrowserAddressInput {
    static func websiteURL(for input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let scheme: String?
        let remainder: Substring
        if let separator = text.range(of: "://"),
           !text[..<separator.lowerBound].contains(where: { "/?#".contains($0) }) {
            let candidate = String(text[..<separator.lowerBound])
                .folding(options: .widthInsensitive, locale: Locale(identifier: "en_US_POSIX")).lowercased()
            guard ["http", "https"].contains(candidate) else { return nil }
            scheme = candidate
            remainder = text[separator.upperBound...]
        } else {
            guard !text.contains(where: \.isWhitespace) else { return nil }
            scheme = nil
            remainder = text[...]
        }
        let end = remainder.firstIndex(where: { "/?#".contains($0) }) ?? remainder.endIndex
        let authority = remainder[..<end]
        guard !authority.isEmpty, !authority.contains(where: \.isWhitespace), !authority.contains("\\") else { return nil }
        let hostStart = authority.lastIndex(of: "@").map { authority.index(after: $0) } ?? authority.startIndex
        let userInfo = String(authority[..<hostStart])
        let rawHostPort = authority[hostStart...]
        let hostPort = foldedHost(String(rawHostPort))
        let suffix = String(remainder[end...])
        let candidate = (scheme ?? "https") + "://" + userInfo + hostPort + suffix
        guard let url = URL(string: candidate), let host = url.host, !host.isEmpty else { return nil }
        if scheme != nil { return url }

        // Bare inputs are address-shaped, rather than arbitrary schemes,
        // sentences or email addresses that URL's permissive parser can accept.
        guard url.user == nil, url.password == nil,
              hostPort.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
                      || ".-:[]".unicodeScalars.contains($0)
              }) else { return nil }
        let hostname = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let isLocal = hostname == "localhost" || hostname.hasPrefix("127.0.0.1") || hostname == "::1"
        let domain = hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard isLocal || hostname.contains(":") || (labels.count >= 2 && labels.allSatisfy({ !$0.isEmpty })) else { return nil }
        if rawHostPort.contains(where: { "。．｡".contains($0) }), !hostPort.unicodeScalars.allSatisfy(\.isASCII) {
            // An IDN plus an ASCII TLD (例子。com) is still address-shaped.
            // Pure Chinese prose (你好。世界) must remain a verbatim search.
            guard let topLevel = labels.last, topLevel.count >= 2,
                  topLevel.unicodeScalars.allSatisfy({ (65...90).contains($0.value) || (97...122).contains($0.value) }) else { return nil }
        }
        if isLocal { return URL(string: "http://" + userInfo + hostPort + suffix) }
        return url
    }

    private static func foldedHost(_ host: String) -> String {
        String(String.UnicodeScalarView(host.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x3002, 0xFF0E, 0xFF61: return UnicodeScalar(46)!
            case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A, 0xFF0D:
                return UnicodeScalar(scalar.value - 0xFEE0)!
            default: return scalar
            }
        }))
    }
}
