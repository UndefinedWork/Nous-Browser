import AppKit
import SwiftUI

struct QuickLinkIcon: View {
    let url: URL
    @State private var image: NSImage?

    init(link: BrowserQuickLink) { url = link.url }
    init(url: URL) { self.url = url }

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
        .task(id: url) {
            image = FaviconStore.shared.cachedImage(for: url)
            let fetched = await FaviconStore.shared.image(for: url)
            guard !Task.isCancelled else { return }
            image = fetched
        }
    }

    private var fallbackSymbol: String {
        switch url.host?.lowercased().replacingOccurrences(of: "www.", with: "") {
        case "apple.com": "apple.logo"
        case "google.com": "magnifyingglass"
        case "wikipedia.org": "book"
        case "chatgpt.com": "bubble.left.and.bubble.right"
        default: "globe"
        }
    }
}
