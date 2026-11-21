import AppKit
import SwiftUI

struct QuickLinkIcon: View {
    private struct Request: Equatable {
        let url: URL
        let hasPreferredImage: Bool
        let discoversDeclaredIcon: Bool
    }

    let url: URL
    let preferredImage: NSImage?
    private let discoversDeclaredIcon: Bool
    @State private var image: NSImage?
    @State private var imageURL: URL

    init(link: BrowserQuickLink) { self.init(url: link.url, discoversDeclaredIcon: true) }
    init(url: URL, preferredImage: NSImage? = nil, discoversDeclaredIcon: Bool = false) {
        self.url = url
        self.preferredImage = preferredImage
        self.discoversDeclaredIcon = discoversDeclaredIcon
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
        .task(id: Request(url: url, hasPreferredImage: preferredImage != nil, discoversDeclaredIcon: discoversDeclaredIcon)) {
            imageURL = url
            if let preferredImage {
                image = preferredImage
                return
            }
            image = FaviconStore.shared.cachedImage(for: url)
            let fetched = discoversDeclaredIcon
                ? await FaviconStore.shared.quickLinkImage(for: url)
                : await FaviconStore.shared.image(for: url)
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

/// Opening a private palette uses only artwork from the app or its own live tabs.
struct PrivateQuickLinkIcon: View {
    let url: URL
    let tabIcon: NSImage?

    var body: some View {
        Group {
            if let icon = tabIcon ?? Self.bundledIcon(for: url) {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "globe").font(.system(size: 15))
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private static let bundledIcons: [String: NSImage] = [
        "apple.com": "apple", "google.com": "google",
        "wikipedia.org": "wikipedia", "chatgpt.com": "chatgpt"
    ].compactMapValues { name in
        Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "QuickLinkIcons")
            .flatMap { NSImage(contentsOf: $0) }
    }

    private static func bundledIcon(for url: URL) -> NSImage? {
        guard url.scheme?.lowercased() == "https", url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return nil }
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return bundledIcons[domain]
    }
}
