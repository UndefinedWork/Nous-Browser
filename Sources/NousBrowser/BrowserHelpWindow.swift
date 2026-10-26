import AppKit
import SwiftUI

/// Local help never hands a website or a search to the system browser.
@MainActor
enum BrowserHelpWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = L10n.string("Keyboard Shortcuts")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: BrowserShortcutHelp())
        window.center()
        Self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}

private struct BrowserShortcutHelp: View {
    private let shortcuts: [(String, String)] = [
        ("New Tab", "⌘T"), ("New Window", "⌘N"),
        ("Close Tab", "⌘W"), ("Close Window", "⇧⌘W"),
        ("Reopen Closed Tab", "⇧⌘T"), ("Open Address…", "⌘L"),
        ("Show Sidebar", "⌘/"), ("Back", "⌘[  /  ⌘←"),
        ("Forward", "⌘]  /  ⌘→"), ("Reload", "⌘R"),
        ("Reload Without Cache", "⇧⌘R"), ("Stop Loading", "⌘."),
        ("Find on Page…", "⌘F"), ("Find Next", "⌘G"),
        ("Find Previous", "⇧⌘G"), ("Next Tab", "⇧⌘]"),
        ("Previous Tab", "⇧⌘["), ("Select Last Tab", "⌘9"),
        ("Zoom In", "⌘+"), ("Zoom Out", "⌘−"), ("Actual Size", "⌘0"),
        ("Copy Current Link", "⇧⌘C"), ("Fill Saved Password…", "⇧⌘P")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Nous Browser").font(.title2.bold())
                Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 14) {
                    ForEach(shortcuts, id: \.0) { title, keys in
                        GridRow {
                            Text(L10n.string(title)).frame(maxWidth: .infinity, alignment: .leading)
                            Text(keys).font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
            .padding(28)
        }
        .scrollIndicators(.hidden)
        .frame(width: 520, height: 600)
    }
}
