import Foundation

/// Reads public HTML declarations for an unloaded shortcut. No page scripts,
/// user cookies, external XML entities, or authenticated WebKit state are used.
enum FaviconDiscovery {
    static let maximumHTMLBytes = 512 * 1024

    static func candidates(for pageURL: URL, using session: URLSession) async -> [URL] {
        guard validPageURL(pageURL) else { return [] }
        var request = URLRequest(url: pageURL)
        request.timeoutInterval = 8
        request.setValue("text/html,application/xhtml+xml;q=0.9", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let finalURL = response.url, validPageURL(finalURL),
                  ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "") else { return [] }
            var data = Data()
            for try await byte in bytes {
                guard !Task.isCancelled else { return [] }
                if data.count == maximumHTMLBytes { break }
                data.append(byte)
                // Do not download a large document body just to find its icon.
                if data.count.isMultiple(of: 4096), headOnly(data).complete { break }
            }
            return candidates(in: data, documentURL: finalURL)
        } catch { return [] }
    }

    static func candidates(in html: Data, documentURL: URL) -> [URL] {
        guard html.count <= maximumHTMLBytes, validPageURL(documentURL),
              let document = try? XMLDocument(data: headOnly(html).html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let head = (try? document.nodes(forXPath: "/html/head"))?.first as? XMLElement else { return [] }
        var baseURL = documentURL
        if let base = head.elements(forName: "base").first(where: { $0.attribute(forName: "href") != nil }),
           let href = base.attribute(forName: "href")?.stringValue,
           let resolved = URL(string: href, relativeTo: documentURL)?.absoluteURL,
           validPageURL(resolved) {
            baseURL = resolved
        }
        var icons: [(url: URL, rank: Int, order: Int)] = []
        for (order, link) in head.elements(forName: "link").enumerated() {
            let rel = (link.attribute(forName: "rel")?.stringValue ?? "").lowercased().split(whereSeparator: \.isWhitespace)
            let isIcon = rel.contains("icon")
            let isTouch = rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed")
            guard isIcon || isTouch,
                  let href = link.attribute(forName: "href")?.stringValue, !href.isEmpty,
                  href.utf8.count <= 2 * 1024 * 1024,
                  let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  url.user == nil, url.password == nil,
                  ["http", "https", "data"].contains(url.scheme?.lowercased() ?? "") else { continue }
            if url.scheme?.lowercased() == "data", !url.absoluteString.lowercased().hasPrefix("data:image/") { continue }
            let type = (link.attribute(forName: "type")?.stringValue ?? "").lowercased().split(separator: ";").first.map(String.init) ?? ""
            guard type.isEmpty || type.trimmingCharacters(in: .whitespaces).hasPrefix("image/") else { continue }
            // Match the live observer's preference: a declared icon before a
            // touch icon, and the last equivalent declaration in tree order.
            icons.append((url, isIcon ? 100 : 0, order))
        }
        icons.sort { $0.rank == $1.rank ? $0.order > $1.order : $0.rank > $1.rank }
        var seen = Set<URL>()
        return Array(icons.compactMap { seen.insert($0.url).inserted ? $0.url : nil }.prefix(8))
    }

    /// HTML Tidy can move a body <link> into the head. Bound its input first so
    /// document content never becomes a shortcut favicon. Raw-text elements are
    /// skipped lexically; fake tags inside scripts/comments cannot end the head.
    private static func headOnly(_ data: Data) -> (html: Data, complete: Bool) {
        let bytes = Array(data)
        let lower = bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }
        let allowed = Set(["html", "head", "base", "link", "meta", "title", "style", "script", "noscript", "noframes", "template"])
        let raw = Set(["title", "style", "script", "noscript", "noframes", "template"])
        var output = Data(), cursor = 0, retained = 0
        func matches(_ text: String, at index: Int) -> Bool {
            let pattern = Array(text.utf8)
            return index + pattern.count <= lower.count && lower[index..<(index + pattern.count)].elementsEqual(pattern)
        }
        func tagEnd(from start: Int) -> Int {
            var index = start, quote: UInt8? = nil
            while index < bytes.count {
                let byte = bytes[index]
                if let delimiter = quote { if byte == delimiter { quote = nil } }
                else if byte == 34 || byte == 39 { quote = byte }
                else if byte == 62 { return index + 1 }
                index += 1
            }
            return bytes.count
        }
        while cursor < bytes.count {
            guard bytes[cursor] == 60 else { cursor += 1; continue }
            if matches("<!--", at: cursor) {
                cursor += 4
                while cursor < bytes.count && !matches("-->", at: cursor) { cursor += 1 }
                cursor = min(cursor + 3, bytes.count)
                continue
            }
            let start = cursor
            cursor += 1
            let closing = cursor < bytes.count && bytes[cursor] == 47
            if closing { cursor += 1 }
            let nameStart = cursor
            while cursor < bytes.count && ((97...122).contains(lower[cursor]) || (48...57).contains(lower[cursor])) { cursor += 1 }
            let name = String(bytes: lower[nameStart..<cursor], encoding: .utf8) ?? ""
            if (closing && name == "head") || (!closing && !name.isEmpty && !allowed.contains(name)) {
                output.append(contentsOf: bytes[retained..<start])
                return (output, true)
            }
            cursor = tagEnd(from: cursor)
            if !closing && raw.contains(name) {
                output.append(contentsOf: bytes[retained..<start])
                let end = "</" + name
                while cursor < bytes.count {
                    if matches(end, at: cursor) {
                        let boundary = cursor + end.utf8.count
                        if boundary == bytes.count || [9, 10, 12, 13, 32, 47, 62].contains(bytes[boundary]) {
                            cursor = tagEnd(from: boundary)
                            break
                        }
                    }
                    cursor += 1
                }
                retained = cursor
            }
        }
        output.append(contentsOf: bytes[retained..<bytes.count])
        return (output, false)
    }

    private static func validPageURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
    }
}
