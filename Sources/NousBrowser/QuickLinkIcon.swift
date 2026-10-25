import AppKit
import SwiftUI

struct QuickLinkIcon: View {
    private struct Request: Equatable {
        let url: URL
        let hasPreferredImage: Bool
    }

    let url: URL
    let preferredImage: NSImage?
    @State private var image: NSImage?
    @State private var imageURL: URL

    init(link: BrowserQuickLink) { self.init(url: link.url) }
    init(url: URL, preferredImage: NSImage? = nil) {
        self.url = url
        self.preferredImage = preferredImage
        _image = State(initialValue: FaviconStore.shared.cachedImage(for: url))
        _imageURL = State(initialValue: url)
    }

    var body: some View {
        Group {
            if let image = preferredImage ?? (imageURL == url ? image : nil) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: fallbackSymbol).font(.system(size: 19, weight: .regular))
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
        .task(id: Request(url: url, hasPreferredImage: preferredImage != nil)) {
            imageURL = url
            if let preferredImage {
                image = preferredImage
                return
            }
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
