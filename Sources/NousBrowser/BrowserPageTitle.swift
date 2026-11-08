import Foundation

/// Some web apps expose a document icon as an emoji title prefix
/// instead of updating rel=icon. Present that explicit prefix in the
/// one icon slot. Keep the original title in the webpage, history and saved sessions.
/// This is presentation only: it never changes the page or its favicon cache.
struct BrowserPageTitle: Equatable {
    let title: String
    let icon: String?

    init(_ original: String) {
        guard let first = original.first, Self.isEmoji(first) else {
            title = original
            icon = nil
            return
        }
        let tail = original.dropFirst()
        let separator = tail.prefix { $0.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) } }
        let name = tail.dropFirst(separator.count)
        guard !separator.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            title = original
            icon = nil
            return
        }
        title = String(name)
        icon = String(first)
    }

    private static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        // isEmoji alone includes ordinary ASCII digits, #, *, © and ®.
        // Preserve those text titles; only accept an actual emoji presentation.
        guard !scalars.contains(where: { $0.value == 0xFE0E }) else { return false }
        if scalars.count == 1, let scalar = scalars.first,
           (0x1F3FB...0x1F3FF).contains(scalar.value) || (0x1F1E6...0x1F1FF).contains(scalar.value) {
            return false // A standalone skin-tone modifier or half a flag.
        }
        if let first = scalars.first,
           (0x30...0x39).contains(first.value) || first == "#" || first == "*" {
            return scalars.contains { $0.value == 0x20E3 } // A complete keycap.
        }
        return scalars.contains { $0.properties.isEmojiPresentation }
            || (scalars.contains { $0.value == 0xFE0F }
                && scalars.contains { $0.properties.isEmoji })
    }
}
