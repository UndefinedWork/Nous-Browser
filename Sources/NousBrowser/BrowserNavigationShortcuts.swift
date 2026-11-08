import AppKit

@MainActor
enum BrowserNavigationShortcuts {
    enum Direction: Equatable { case back, forward }

    static func direction(for event: NSEvent) -> Direction? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard event.type == .keyDown, modifiers == .command else { return nil }
        switch event.keyCode {
        case 123: return .back
        case 124: return .forward
        default: return nil
        }
    }

    static func shouldPreserveTextEditing(in window: NSWindow, webView: BrowserPageView) -> Bool {
        if let text = window.firstResponder as? NSText, text.isEditable || text.isSelectable { return true }
        guard let responder = window.firstResponder as? NSView else { return false }
        if responder === webView || responder.isDescendant(of: webView) {
            // Renderer-owned shortcuts use Chromium's native editing path;
            // this fallback only guards the active native input context.
            return webView.inputContext != nil
        }
        return responder.inputContext != nil
    }
}

/// Alternate browser shortcuts that cannot share a SwiftUI menu key equivalent.
@MainActor
enum BrowserShortcutAliases {
    enum Action: Equatable { case nextTab, previousTab, zoomIn }

    static func action(for event: NSEvent) -> Action? {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.keyCode == 48 {
            if modifiers == .control { return .nextTab }
            if modifiers == [.control, .shift] { return .previousTab }
        }
        if modifiers == [.command, .option] {
            if event.keyCode == 124 { return .nextTab }
            if event.keyCode == 123 { return .previousTab }
        }
        // “+” may require Shift on the active keyboard layout; ⌘= is the menu alias.
        if (modifiers == .command || modifiers == [.command, .shift]),
           event.charactersIgnoringModifiers == "+" { return .zoomIn }
        return nil
    }
}

/// Alloy sends Command equivalents to the renderer before trying the main
/// menu. Reserve only browser navigation/address/tab/sidebar commands present
/// in our menu, so a page cannot swallow them with preventDefault(). Editing
/// commands and composition keys retain the normal responder/renderer path.
@MainActor
enum ChromiumReservedBrowserShortcuts {
    static func isReserved(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let characters = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        switch modifiers {
        case .command:
            return ["l", "t", "n", "w", "r", "[", "]", "/", ".", "1", "2", "3", "4", "5", "6", "7", "8", "9"].contains(characters)
        case [.command, .shift]:
            // Braces are the shifted bracket equivalents on common layouts;
            // AppKit still resolves the exact menu shortcut for that layout.
            return ["t", "w", "r", "[", "]", "{", "}"].contains(characters)
        default:
            return false
        }
    }

    /// Dispatch through the existing menu to retain its action and enabled
    /// state. A disabled reserved command stays reserved rather than leaking to
    /// the page (for example Back on the first history entry).
    @discardableResult
    static func dispatch(_ event: NSEvent, through menu: NSMenu?) -> Bool {
        guard isReserved(event) else { return false }
        // Chrome discards repeats of new-tab/new-window commands. A held key
        // must not create a burst of pages; keep all other commands repeatable.
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.isARepeat, modifiers == .command,
           let characters = event.charactersIgnoringModifiers?.lowercased(),
           characters == "t" || characters == "n" { return true }
        _ = menu?.performKeyEquivalent(with: event)
        return true
    }
}

/// Webpage arrows use Chromium's native key handling; browser chrome is handled
/// here without overriding native text editing or involving other windows.
@MainActor
final class BrowserWindow: NSWindow {
    weak var browserController: BrowserController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isKeyWindow, let controller = browserController,
              attachedSheet == nil, !controller.passwords.isPresented else {
            return super.performKeyEquivalent(with: event)
        }
        if ChromiumReservedBrowserShortcuts.dispatch(event, through: NSApp.mainMenu) {
            return true
        }
        if let action = BrowserShortcutAliases.action(for: event) {
            switch action {
            case .nextTab: controller.selectNextTab()
            case .previousTab: controller.selectNextTab(backward: true)
            case .zoomIn:
                guard controller.model.selectedTab?.hasWebContent == true else {
                    return super.performKeyEquivalent(with: event)
                }
                controller.model.zoomIn()
            }
            return true
        }
        guard let direction = BrowserNavigationShortcuts.direction(for: event),
              let tab = controller.model.selectedTab,
              !controller.isAddressPresented, !controller.find.isPresented else {
            return super.performKeyEquivalent(with: event)
        }
        if let responder = firstResponder as? NSView,
           responder === tab.webView || responder.isDescendant(of: tab.webView) {
            return super.performKeyEquivalent(with: event)
        }
        guard !BrowserNavigationShortcuts.shouldPreserveTextEditing(in: self, webView: tab.webView) else {
            return super.performKeyEquivalent(with: event)
        }
        switch direction {
        case .back:
            guard tab.canGoBack else { return super.performKeyEquivalent(with: event) }
            controller.model.goBack()
        case .forward:
            guard tab.canGoForward else { return super.performKeyEquivalent(with: event) }
            controller.model.goForward()
        }
        return true
    }
}
