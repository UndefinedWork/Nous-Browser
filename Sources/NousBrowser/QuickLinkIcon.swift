import AppKit
import SwiftUI

struct QuickLinkIcon: View {
    let link: BrowserQuickLink
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: fallbackSymbol).font(.system(size: 19, weight: .regular))
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
        .task(id: link.url) {
            image = FaviconStore.shared.cachedImage(for: link.url)
            let fetched = await FaviconStore.shared.image(for: link.url)
            guard !Task.isCancelled else { return }
            image = fetched
        }
    }

    private var fallbackSymbol: String {
        switch link.url.host?.lowercased().replacingOccurrences(of: "www.", with: "") {
        case "apple.com": "apple.logo"
        case "google.com": "magnifyingglass"
        case "wikipedia.org": "book"
        case "chatgpt.com": "bubble.left.and.bubble.right"
        default: "globe"
        }
    }
}
