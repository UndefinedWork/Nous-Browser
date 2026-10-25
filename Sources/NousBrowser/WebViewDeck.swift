import AppKit
import SwiftUI
import WebKit

/// Hosts every recently used web view in one AppKit container. Switching tabs
/// only toggles `isHidden`, so WebKit never has to detach and re-attach a page
/// to the window, which was the main cost of a tab switch.
struct WebViewDeck: NSViewRepresentable {
    let tabs: [BrowserTab]
    let selectedID: UUID?

    func makeNSView(context: Context) -> WebViewDeckView { WebViewDeckView() }
    func updateNSView(_ deck: WebViewDeckView, context: Context) { deck.show(tabs, selectedID: selectedID) }
}

@MainActor
final class WebViewDeckView: NSView {
    /// Hidden pages beyond this many stay detached until they are shown again.
    nonisolated static let attachedLimit = 8

    private var recentIDs: [UUID] = []

    override var isFlipped: Bool { true }

    func show(_ tabs: [BrowserTab], selectedID: UUID?) {
        let liveIDs = Set(tabs.map(\.id))
        recentIDs.removeAll { !liveIDs.contains($0) }
        if let selectedID {
            recentIDs.removeAll { $0 == selectedID }
            recentIDs.insert(selectedID, at: 0)
        }
        let attachedIDs = Self.attachedIDs(recent: recentIDs, eligible: Set(tabs.filter(\.hasWebContent).map(\.id)))
        // AppKit moves focus to an arbitrary key view when a focused view is
        // hidden, so note which page had focus before changing visibility.
        let focusedPage = (window?.firstResponder as? NSView).flatMap { responder in
            subviews.first { responder.isDescendant(of: $0) } as? WKWebView
        }

        var selectedView: WKWebView?
        for tab in tabs {
            let view = tab.webView
            guard attachedIDs.contains(tab.id) else {
                if view.superview === self { view.removeFromSuperview() }
                continue
            }
            // A page in element fullscreen lives in WebKit's fullscreen window.
            // WebKit returns it here when fullscreen ends; never pull it back.
            if view.superview == nil {
                view.frame = bounds
                view.autoresizingMask = [.width, .height]
                addSubview(view)
            }
            guard view.superview === self else { continue }
            let isSelected = tab.id == selectedID
            if view.isHidden == isSelected { view.isHidden = !isSelected }
            if isSelected { selectedView = view }
        }
        // Closed tabs are no longer in `tabs`; release their views.
        for case let view as WKWebView in subviews where !tabs.contains(where: { $0.webView === view }) {
            view.removeFromSuperview()
        }
        // Removing a view from the window used to resign its focus implicitly.
        // Typing must follow the visible page, never a hidden or detached one.
        if let focusedPage, focusedPage !== selectedView {
            window?.makeFirstResponder(selectedView)
        }
    }

    /// The selected page first, then the most recently shown pages.
    nonisolated static func attachedIDs(recent: [UUID], eligible: Set<UUID>, limit: Int = attachedLimit) -> Set<UUID> {
        Set(recent.lazy.filter { eligible.contains($0) }.prefix(limit))
    }
}
