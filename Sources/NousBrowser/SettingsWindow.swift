import AppKit
import SwiftUI

/// Settings in the Safari / System style: one toolbar button per pane (the
/// system draws the Liquid Glass selection), the window titled after the pane,
/// and the window growing or shrinking to fit each pane.
@MainActor
final class SettingsWindowController: NSWindowController {
    struct Pane {
        let id: String
        let title: String
        let symbol: String
        let view: AnyView
    }

    private static let selectionKey = "settings.selectedPane"

    convenience init(panes: [Pane]) {
        let tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        for pane in panes {
            let hosting = NSHostingController(rootView: pane.view)
            hosting.sizingOptions = [.preferredContentSize]
            hosting.title = pane.title
            let item = NSTabViewItem(viewController: hosting)
            item.identifier = pane.id
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let saved = UserDefaults.standard.string(forKey: Self.selectionKey)
        if let index = panes.firstIndex(where: { $0.id == saved }) { tabs.selectedTabViewItemIndex = index }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("NousSettings")
        self.init(window: window)
        tabs.onSelect = { id in UserDefaults.standard.set(id, forKey: Self.selectionKey) }
        tabs.fitWindow(animated: false)
        if !window.setFrameUsingName("NousSettings") { window.center() }
        tabs.fitWindow(animated: false)
    }
}

private final class SettingsTabViewController: NSTabViewController {
    var onSelect: ((String) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String { onSelect?(id) }
        view.window?.title = tabViewItem?.label ?? ""
        fitWindow(animated: true)
    }

    /// A pane's ideal size changed (a list grew, a disclosure opened).
    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        guard viewController === tabView.selectedTabViewItem?.viewController else { return }
        fitWindow(animated: true)
    }

    /// Keeps the window's top edge in place, the way Safari's Settings resize.
    func fitWindow(animated: Bool) {
        guard let window = view.window, let pane = tabView.selectedTabViewItem?.viewController else { return }
        window.title = tabView.selectedTabViewItem?.label ?? ""
        let size = pane.preferredContentSize
        guard size.width > 0, size.height > 0 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        guard frame != window.frame else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(frame, display: true, animate: animated && window.isVisible && !reduceMotion)
    }
}

// MARK: - Layout

enum SettingsMetrics {
    static let width: CGFloat = 640
    static let controlWidth: CGFloat = 260
    static let noteWidth: CGFloat = 320
}

/// The two-column form of macOS settings: right-aligned labels, controls
/// left-aligned beside them, the block centred in the pane.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 16) {
            content
        }
        .padding(.horizontal, 40)
        .padding(.top, 30)
        .padding(.bottom, 34)
        .frame(width: SettingsMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsRow<Content: View>: View {
    /// Localization key; nil continues the previous row's label.
    let label: String?
    @ViewBuilder var content: Content

    init(_ label: String?, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        GridRow {
            Group {
                if let label { Text(L10n.format("%@:", L10n.string(label))).multilineTextAlignment(.trailing) }
                else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
            }
            .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 6) { content }
                .gridColumnAlignment(.leading)
        }
    }
}

/// Extra space between groups of rows, as in Safari's General pane.
struct SettingsGap: View {
    var body: some View {
        GridRow { Color.clear.frame(height: 2).gridCellColumns(2) }
    }
}

/// Small grey text under the control it explains.
struct SettingsNote: View {
    let text: String
    init(_ key: String) { text = L10n.string(key) }
    init(verbatim: String) { text = verbatim }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: SettingsMetrics.noteWidth, alignment: .leading)
    }
}

/// A bordered list box like the ones in Safari's Websites and Extensions panes.
struct SettingsListBox<Content: View>: View {
    var height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 0) { content }
        }
        .scrollIndicators(.automatic)
        .frame(height: height)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}
