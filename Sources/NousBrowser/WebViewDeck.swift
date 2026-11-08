import AppKit
import SwiftUI

/// Hosts every recently used web view in one AppKit container. Switching tabs
/// only toggles `isHidden`, so Chromium normally keeps the same native view attached
/// to the window; inactive renderers retain their native lifecycle state.
struct WebViewDeck: NSViewRepresentable {
    let tabs: [BrowserTab]
    let selectedID: UUID?
    var owner: BrowserModel? = nil

    func makeNSView(context: Context) -> WebViewDeckView { WebViewDeckView() }
    func updateNSView(_ deck: WebViewDeckView, context: Context) { deck.show(tabs, selectedID: selectedID, owner: owner) }
}

@MainActor
final class WebViewDeckView: NSView {
    /// Hidden pages beyond this many stay detached until they are shown again.
    nonisolated static let attachedLimit = 8

    private var recentIDs: [UUID] = []

    override var isFlipped: Bool { true }

    func show(_ proposedTabs: [BrowserTab], selectedID: UUID?, owner: BrowserModel? = nil) {
        // A delayed SwiftUI update from the former window cannot reclaim a
        // transferred view after the tab has changed owners.
        let tabs = proposedTabs.filter { tab in owner.map { tab.isOwned(by: $0) } ?? true }
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
            subviews.first { responder.isDescendant(of: $0) } as? BrowserPageView
        }

        var selectedView: BrowserPageView?
        for tab in tabs {
            let view = tab.webView
            // Each window's selected page is active, including a non-key or
            // minimized window. Chromium receives its own eligibility inputs.
            if let owner { owner.synchronizeChromiumLifecycleState(for: tab) }
            else { tab.synchronizeNativeLifecycle(activeInWindow: tab.id == selectedID) }
            guard attachedIDs.contains(tab.id) else {
                if view.superview === self { view.removeFromSuperview() }
                continue
            }
            // Preserve a native view owned by another presentation container.
            // Only a deliberate transfer between page decks may reclaim it.
            if owner != nil, view.superview is WebViewDeckView, view.superview !== self {
                view.removeFromSuperview()
            }
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
        for case let view as BrowserPageView in subviews where !tabs.contains(where: { $0.webView === view }) {
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
