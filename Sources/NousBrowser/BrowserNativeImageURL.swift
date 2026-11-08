import Foundation

/// Only native image context-menu actions may open a page-owned image URL.
/// External URLs, address entry and automation keep their existing policy.
nonisolated enum BrowserNativeImageURL {
    static func allows(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return !(url.host ?? "").isEmpty
        case "data":
            let value = url.absoluteString.dropFirst(5)
            guard let comma = value.firstIndex(of: ",") else { return false }
            let type = value[..<comma].split(separator: ";", omittingEmptySubsequences: false).first?.lowercased() ?? ""
            return type.hasPrefix("image/") && type.count > "image/".count
        case "blob":
            let value = String(url.absoluteString.dropFirst(5))
            // Sandboxed documents can legitimately create opaque-origin blobs.
            if value.hasPrefix("null/") { return value.count > "null/".count }
            guard let origin = URL(string: value),
                  ["http", "https"].contains(origin.scheme?.lowercased() ?? ""),
                  !(origin.host ?? "").isEmpty, origin.path.count > 1 else { return false }
            return origin.user == nil && origin.password == nil
        default:
            return false
        }
    }
}
