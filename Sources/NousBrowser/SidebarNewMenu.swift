import AppKit
import SwiftUI

/// The sidebar's “Add New” button (Pico 448:1297): one press opens a menu of
/// everything you can create or start — tabs, groups, windows, spaces,
/// screenshots and recordings — plus Settings.
struct SidebarNewMenuButton: View {
    let controller: BrowserController
    let newGroup: () -> Void
    let newSpace: () -> Void
    @State private var anchor = MenuAnchor()

    var body: some View {
        let label = L10n.string("Add New")
        GlassSymbolButton("plus", label: label, help: label, symbolSize: BrowserDesign.topSymbolSize,
                          symbolWeight: .medium) {
            guard let view = anchor.view else { controller.newTab(); return }
            SidebarNewMenu(controller: controller, newGroup: newGroup, newSpace: newSpace).popUp(below: view)
        }
        .background { MenuAnchorView(anchor: anchor) }
    }
}

/// Holds the AppKit view the menu opens from.
@MainActor
private final class MenuAnchor {
    weak var view: NSView?
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}

/// A native menu, so it gets the system's Liquid Glass look, keyboard
/// navigation and VoiceOver for free.
@MainActor
final class SidebarNewMenu: NSObject {
    private let controller: BrowserController
    private let newGroup: () -> Void
    private let newSpace: () -> Void

    init(controller: BrowserController, newGroup: @escaping () -> Void, newSpace: @escaping () -> Void) {
        self.controller = controller
        self.newGroup = newGroup
        self.newSpace = newSpace
    }

    private final class Item: NSMenuItem {
        var run: () -> Void = {}
    }

    private var animation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : BrowserMotion.spring
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let capture = CaptureCoordinator.shared
        menu.items = [
            item("New Tab", "plus", key: "t") { [controller] in controller.newTab() },
            item("New Group", "folder.badge.plus") { [newGroup] in newGroup() },
            item("New Window", "macwindow.badge.plus", key: "n") { [controller] in controller.newWindow() },
            spacesItem(),
            .separator(),
            captureItem(.screenshot, "Screenshot", "camera.viewfinder") { capture.takeScreenshot() },
            captureItem(.recording, capture.isRecording ? "Stop Recording" : "Record Screen",
                        capture.isRecording ? "stop.circle" : "record.circle") { capture.toggleRecording() },
            .separator(),
            item("Settings", "gearshape", key: ",") {
                NSApp.sendAction(#selector(BrowserAppDelegate.showSettings(_:)), to: nil, from: nil)
            },
        ]
        return menu
    }

    private func spacesItem() -> NSMenuItem {
        let model = controller.model
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for space in model.spaces {
            let entry = Item(title: space.name, action: #selector(run(_:)), keyEquivalent: "")
            entry.target = self
            entry.image = Self.icon(space.icon)
            entry.state = space.id == model.activeSpaceID ? .on : .off
            entry.run = { [animation] in withAnimation(animation) { model.switchSpace(to: space.id) } }
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(item("New Space", "plus.square.on.square") { [newSpace] in newSpace() })

        let parent = NSMenuItem(title: L10n.string("Spaces"), action: nil, keyEquivalent: "")
        parent.image = Self.icon("square.stack.3d.up")
        parent.submenu = submenu
        return parent
    }

    private func item(_ key: String, _ symbol: String, key equivalent: String = "",
                      run: @escaping () -> Void) -> NSMenuItem {
        let item = Item(title: L10n.string(key), action: #selector(run(_:)), keyEquivalent: equivalent)
        item.keyEquivalentModifierMask = equivalent.isEmpty ? [] : .command
        item.target = self
        item.image = Self.icon(symbol)
        item.run = run
        return item
    }

    /// Capture items show the shortcut chosen in Settings.
    private func captureItem(_ action: CaptureShortcuts.Action, _ key: String, _ symbol: String,
                             run: @escaping () -> Void) -> NSMenuItem {
        let menuItem = item(key, symbol, run: run)
        if let shortcut = CaptureShortcuts.shared.shortcut(action), let equivalent = shortcut.keyEquivalent {
            menuItem.keyEquivalent = equivalent
            menuItem.keyEquivalentModifierMask = shortcut.flags
        }
        return menuItem
    }

    @objc private func run(_ sender: NSMenuItem) {
        // Let the menu finish closing before a window, sheet or overlay opens.
        let action = (sender as? Item)?.run
        DispatchQueue.main.async { action?() }
    }

    /// Opens under the button, its leading edge lined up with the button's.
    func popUp(below view: NSView) {
        let menu = makeMenu()
        let gap: CGFloat = 6
        let point = NSPoint(x: view.bounds.minX, y: view.isFlipped ? view.bounds.maxY + gap : view.bounds.minY - gap)
        // The menu keeps no reference to its targets; hold on while it is open.
        withExtendedLifetime(self) { _ = menu.popUp(positioning: nil, at: point, in: view) }
    }

    /// An SF Symbol, or a space's emoji drawn at menu-icon size.
    static func icon(_ name: String) -> NSImage? {
        if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            return symbol.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        }
        guard !name.isEmpty else { return nil }
        let size = NSSize(width: 16, height: 16)
        return NSImage(size: size, flipped: false) { rect in
            let text = name as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
            let bounds = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2), withAttributes: attributes)
            return true
        }
    }
}
