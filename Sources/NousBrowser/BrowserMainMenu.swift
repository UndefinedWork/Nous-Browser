import AppKit
import SwiftUI

/// AppKit main menu. Chromium owns the run loop (Dia-style embedding), so the
/// SwiftUI App/Commands lifecycle is unavailable; this mirrors the former
/// `BrowserCommands` item for item, including shortcuts and enablement.
@MainActor
final class BrowserMainMenu: NSObject, NSMenuItemValidation, NSMenuDelegate {
    let menu = NSMenu(title: "Main")
    let servicesMenu = NSMenu(title: L10n.string("Services"))
    let windowsMenu = NSMenu(title: L10n.string("Window"))
    let helpMenu = NSMenu(title: L10n.string("Help"))

    private weak var delegate: BrowserAppDelegate?
    private var windows: BrowserWindowManager? { delegate?.windowManager }
    private var controller: BrowserController? { windows?.keyController }
    private var sidebarAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : BrowserMotion.spring
    }

    private final class Item: NSMenuItem {
        var run: () -> Void = {}
        var isAvailable: () -> Bool = { true }
        var dynamicTitle: (() -> String)?
        var captureAction: CaptureShortcuts.Action?
    }

    init(delegate: BrowserAppDelegate) {
        self.delegate = delegate
        super.init()
        build()
    }

    // MARK: Building

    private func item(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
                      enabled: @escaping () -> Bool = { true }, title dynamicTitle: (() -> String)? = nil,
                      run: @escaping () -> Void) -> NSMenuItem {
        let item = Item(title: title, action: #selector(runMenuItem(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = self
        item.run = run
        item.isAvailable = enabled
        item.dynamicTitle = dynamicTitle
        return item
    }

    /// Capture items show the shortcut chosen in Settings.
    private func capture(_ action: CaptureShortcuts.Action, _ menuItem: NSMenuItem) -> NSMenuItem {
        (menuItem as? Item)?.captureAction = action
        applyCaptureShortcut(to: menuItem)
        return menuItem
    }

    private func applyCaptureShortcut(to menuItem: NSMenuItem) {
        guard let action = (menuItem as? Item)?.captureAction else { return }
        if let shortcut = CaptureShortcuts.shared.shortcut(action), let key = shortcut.keyEquivalent {
            menuItem.keyEquivalent = key
            menuItem.keyEquivalentModifierMask = shortcut.flags
        } else {
            menuItem.keyEquivalent = ""
            menuItem.keyEquivalentModifierMask = []
        }
    }

    private func system(_ title: String, _ action: Selector, _ key: String = "",
                        _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem], menu existing: NSMenu? = nil) {
        let sub = existing ?? NSMenu(title: title)
        sub.title = title
        sub.delegate = self
        items.forEach(sub.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = sub
        menu.addItem(holder)
    }

    private func build() {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Nous Browser"
        var app: [NSMenuItem] = [
            system(L10n.format("About %@", appName), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
        ]
        if BrowserUpdater.shared.isEnabled {
            app.append(item(L10n.string("Check for Updates…")) { BrowserUpdater.shared.checkForUpdates() })
        }
        let services = NSMenuItem(title: L10n.string("Services"), action: nil, keyEquivalent: "")
        services.submenu = servicesMenu
        let hideOthers = system(L10n.string("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h",
                                [.command, .option])
        app += [
            .separator(),
            item(L10n.string("Settings…"), ",") { [weak self] in self?.delegate?.showSettings(nil) },
            .separator(), services, .separator(),
            system(L10n.format("Hide %@", appName), #selector(NSApplication.hide(_:)), "h"),
            hideOthers,
            system(L10n.string("Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            system(L10n.format("Quit %@", appName), #selector(NSApplication.terminate(_:)), "q"),
        ]
        submenu(appName, app)

        let hasPageNow: () -> Bool = { [weak self] in self?.controller?.model.selectedTab?.hasWebContent == true }
        submenu(L10n.string("File"), [
            item(L10n.string("New Tab"), "t") { [weak self] in
                self?.windows?.newTab()
                self?.windows?.showWindow()
            },
            item(L10n.string("New Window"), "n") { [weak self] in self?.windows?.newWindow() },
            item(L10n.string("Open Address…"), "l", enabled: { [weak self] in self?.controller != nil }) { [weak self] in
                self?.controller?.toggleAddress()
            },
            .separator(),
            // ⌘W closes the tab while a browser window is key, else the window.
            item(L10n.string("Close Tab"), "w",
                 title: { [weak self] in L10n.string(self?.controller == nil ? "Close Window" : "Close Tab") }) { [weak self] in
                if let controller = self?.controller { controller.closeTab() }
                else { NSApp.keyWindow?.performClose(nil) }
            },
            item(L10n.string("Close Window"), "w", [.command, .shift]) { [weak self] in
                if self?.controller != nil { self?.windows?.closeActiveWindow() }
                else { NSApp.keyWindow?.performClose(nil) }
            },
            item(L10n.string("Reopen Closed Tab"), "t", [.command, .shift],
                 enabled: { [weak self] in self?.controller?.model.canRestoreClosedTab == true }) { [weak self] in
                self?.controller?.model.restoreClosedTab()
            },
            .separator(),
            item(L10n.string("Print…"), "p", enabled: { [weak self] in
                self?.controller?.model.selectedTab?.hasWebContent == true && NSApp.keyWindow?.attachedSheet == nil
            }) { [weak self] in self?.controller?.model.selectedTab?.webView.printPage() },
            .separator(),
            item(L10n.string("Library"), "l", [.command, .shift]) { [weak self] in self?.openLibrary(.all) },
            item(L10n.string("Downloads"), "j", [.command, .shift]) { [weak self] in self?.openLibrary(.downloads) },
            item(L10n.string("History"), "y") { [weak self] in self?.openLibrary(.history) },
            item(L10n.string("Bookmarks"), "b", [.command, .option]) { [weak self] in self?.openLibrary(.bookmarks) },
            item(L10n.string("Add Bookmark"), "d",
                 enabled: { [weak self] in self?.controller?.model.selectedTab?.hasWebContent == true },
                 title: { [weak self] in
                     L10n.string(LibraryStore.shared.isBookmarked(self?.controller?.model.selectedTab?.url) ? "Remove Bookmark" : "Add Bookmark")
                 }) { [weak self] in
                self?.controller?.toggleBookmark()
            },
            .separator(),
            capture(.screenshot, item(L10n.string("Take Screenshot")) { CaptureCoordinator.shared.takeScreenshot() }),
            capture(.capturePage, item(L10n.string("Capture Page"), enabled: hasPageNow) { [weak self] in
                CaptureCoordinator.shared.capturePage(self?.controller?.model.selectedTab)
            }),
            capture(.recording, item(L10n.string("Record Screen"),
                 title: { L10n.string(CaptureCoordinator.shared.isRecording ? "Stop Recording" : "Record Screen") }) {
                CaptureCoordinator.shared.toggleRecording()
            }),
        ])

        let hasPage: () -> Bool = { [weak self] in self?.controller?.model.selectedTab?.hasWebContent == true }
        submenu(L10n.string("Edit"), [
            system(L10n.string("Undo"), Selector(("undo:")), "z"),
            system(L10n.string("Redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            system(L10n.string("Cut"), #selector(NSText.cut(_:)), "x"),
            system(L10n.string("Copy"), #selector(NSText.copy(_:)), "c"),
            system(L10n.string("Paste"), #selector(NSText.paste(_:)), "v"),
            system(L10n.string("Paste and Match Style"), #selector(NSTextView.pasteAsPlainText(_:)), "v",
                   [.command, .option, .shift]),
            system(L10n.string("Delete"), #selector(NSText.delete(_:))),
            system(L10n.string("Select All"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item(L10n.string("Find on Page…"), "f", enabled: hasPage) { [weak self] in self?.controller?.showFind() },
            item(L10n.string("Find Next"), "g", enabled: hasPage) { [weak self] in self?.controller?.find.findNext() },
            item(L10n.string("Find Previous"), "g", [.command, .shift], enabled: hasPage) { [weak self] in
                self?.controller?.find.findNext(backward: true)
            },
        ])

        let hasController: () -> Bool = { [weak self] in self?.controller != nil }
        var view: [NSMenuItem] = [
            item(L10n.string("Collapse Sidebar"), "/", enabled: hasController, title: { [weak self] in
                let model = self?.controller?.model
                return L10n.string(model?.isSidebarVisible == true && model?.isSidebarCompact == false
                                   ? "Collapse Sidebar" : "Expand Sidebar")
            }) { [weak self] in
                withAnimation(self?.sidebarAnimation) { self?.controller?.model.toggleSidebar() }
            },
            item(L10n.string("Hide Sidebar"), ".", enabled: hasController, title: { [weak self] in
                L10n.string(self?.controller?.model.isSidebarVisible == true ? "Hide Sidebar" : "Show Sidebar")
            }) { [weak self] in
                withAnimation(self?.sidebarAnimation) { self?.controller?.model.toggleSidebarHidden() }
            },
            .separator(),
            item(L10n.string("Next Tab"), "]", [.command, .shift], enabled: hasController) { [weak self] in
                self?.controller?.selectNextTab()
            },
            item(L10n.string("Previous Tab"), "[", [.command, .shift], enabled: hasController) { [weak self] in
                self?.controller?.selectNextTab(backward: true)
            },
            .separator(),
            item(L10n.string("Next Space"), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option], enabled: hasController) { [weak self] in
                withAnimation(BrowserMotion.spring) { self?.controller?.model.switchSpace(by: 1) }
            },
            item(L10n.string("Previous Space"), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option], enabled: hasController) { [weak self] in
                withAnimation(BrowserMotion.spring) { self?.controller?.model.switchSpace(by: -1) }
            },
            item(L10n.string("New Space"), enabled: hasController) { [weak self] in
                withAnimation(BrowserMotion.spring) { self?.controller?.model.newSpace() }
            },
            item(L10n.string("New Group"), "n", [.command, .option], enabled: hasController) { [weak self] in
                withAnimation(BrowserMotion.spring) { _ = self?.controller?.model.newGroup() }
            },
            .separator(),
        ]
        for number in 1..<9 {
            view.append(item(L10n.format("Select Tab %d", number), String(number),
                             enabled: { [weak self] in (self?.controller?.model.visibleTabs.count ?? 0) >= number }) { [weak self] in
                self?.controller?.selectTab(number: number)
            })
        }
        view += [
            item(L10n.string("Select Last Tab"), "9", enabled: hasController) { [weak self] in
                self?.controller?.selectTab(number: 9)
            },
            .separator(),
            item(L10n.string("Zoom In"), "=", enabled: hasPage) { [weak self] in self?.controller?.model.zoomIn() },
            item(L10n.string("Zoom Out"), "-", enabled: hasPage) { [weak self] in self?.controller?.model.zoomOut() },
            item(L10n.string("Actual Size"), "0", enabled: hasPage) { [weak self] in self?.controller?.model.resetZoom() },
            .separator(),
            system(L10n.string("Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]
        submenu(L10n.string("View"), view)

        submenu(L10n.string("Navigate"), [
            item(L10n.string("Back"), "[", enabled: { [weak self] in self?.controller?.model.selectedTab?.canGoBack == true }) {
                [weak self] in self?.controller?.model.goBack()
            },
            item(L10n.string("Forward"), "]", enabled: { [weak self] in self?.controller?.model.selectedTab?.canGoForward == true }) {
                [weak self] in self?.controller?.model.goForward()
            },
            item(L10n.string("Reload"), "r", enabled: hasPage) { [weak self] in self?.controller?.model.reload() },
            item(L10n.string("Reload Without Cache"), "r", [.command, .shift], enabled: hasPage) { [weak self] in
                self?.controller?.model.reload(bypassingCache: true)
            },
            item(L10n.string("Stop Loading"), enabled: { [weak self] in self?.controller?.model.selectedTab?.isLoading == true }) {
                [weak self] in self?.controller?.model.stopLoading()
            },
            .separator(),
            item(L10n.string("Copy Current Link"), "c", [.command, .shift],
                 enabled: { [weak self] in self?.controller?.model.selectedTab?.url != nil }) { [weak self] in
                self?.controller?.copyURL()
            },
        ])

        submenu(L10n.string("Passwords"), [
            item(L10n.string("Fill Saved Password…"), "p", [.command, .shift],
                 enabled: { [weak self] in self?.controller?.passwords.canFill == true }) { [weak self] in
                self?.controller?.passwords.presentFill()
            },
        ])

        submenu(L10n.string("Window"), [
            system(L10n.string("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            system(L10n.string("Zoom"), #selector(NSWindow.performZoom(_:))),
            .separator(),
            system(L10n.string("Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
        ], menu: windowsMenu)

        submenu(L10n.string("Help"), [
            item(L10n.string("Keyboard Shortcuts")) { BrowserHelpWindow.show() },
        ], menu: helpMenu)
    }

    // MARK: Actions and validation

    private func openLibrary(_ section: LibrarySection) {
        if controller == nil { windows?.showWindow() }
        controller?.dismissAddress()
        controller?.model.openNativePage(.library(section))
    }

    @objc private func runMenuItem(_ sender: NSMenuItem) {
        (sender as? Item)?.run()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let item = menuItem as? Item else { return true }
        if let title = item.dynamicTitle?() { item.title = title }
        return item.isAvailable()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for case let item as Item in menu.items {
            if let title = item.dynamicTitle?() { item.title = title }
            applyCaptureShortcut(to: item)
        }
    }
}
