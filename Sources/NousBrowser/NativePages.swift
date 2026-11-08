import Foundation

nonisolated enum LibrarySection: String, CaseIterable, Identifiable, Sendable {
    case all, bookmarks, screenshots, recordings, history, downloads, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.string("All")
        case .bookmarks: L10n.string("Bookmarks")
        case .screenshots: L10n.string("Screenshots")
        case .recordings: L10n.string("Recordings")
        case .history: L10n.string("History")
        case .downloads: L10n.string("Downloads")
        case .updates: L10n.string("Updates")
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .bookmarks: "star"
        case .screenshots: "photo"
        case .recordings: "video"
        case .history: "clock"
        case .downloads: "arrow.down.circle"
        case .updates: "sparkles"
        }
    }
}

/// Pages Nous draws itself inside a tab: `nous://library`, `nous://screenshot/<file>`.
nonisolated enum NativePage: Equatable, Hashable, Sendable {
    case library(LibrarySection)
    case screenshot(String)
    case recording(String)

    static let scheme = "nous"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host?.lowercased() else { return nil }
        let item = url.pathComponents.dropFirst().first.map { $0.removingPercentEncoding ?? $0 }
        switch host {
        case "library": self = .library(item.flatMap(LibrarySection.init(rawValue:)) ?? .all)
        case "screenshot": guard let item, !item.isEmpty else { return nil }; self = .screenshot(item)
        case "recording": guard let item, !item.isEmpty else { return nil }; self = .recording(item)
        default: return nil
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .library(let section):
            components.host = "library"
            components.path = section == .all ? "" : "/" + section.rawValue
        case .screenshot(let file):
            components.host = "screenshot"
            components.path = "/" + file
        case .recording(let file):
            components.host = "recording"
            components.path = "/" + file
        }
        return components.url!
    }

    func title(fallback: String) -> String {
        switch self {
        case .library: L10n.string("Library")
        case .screenshot(let file): (file as NSString).deletingPathExtension
        case .recording(let file): (file as NSString).deletingPathExtension
        }
    }

    var symbol: String {
        switch self {
        case .library: "books.vertical"
        case .screenshot: "camera.viewfinder"
        case .recording: "record.circle"
        }
    }

    var isLibrary: Bool { if case .library = self { true } else { false } }
}

import SwiftUI

/// The page area for a native tab.
struct NativePageView: View {
    let controller: BrowserController
    let page: NativePage

    var body: some View {
        switch page {
        case .library(let section):
            LibraryView(controller: controller, section: section)
        case .screenshot, .recording:
            if let capture = LibraryStore.shared.capture(for: page) {
                if capture.kind == .screenshot { ScreenshotEditorView(capture: capture) }
                else { RecordingEditorView(capture: capture) }
            } else {
                CaptureUnavailableView(name: page.title(fallback: ""))
            }
        }
    }
}
