import AppKit
import WebKit

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

    static func shouldPreserveTextEditing(in window: NSWindow, webView: WKWebView) -> Bool {
        if let text = window.firstResponder as? NSText, text.isEditable || text.isSelectable { return true }
        guard let responder = window.firstResponder as? NSView else { return false }
        if responder === webView || responder.isDescendant(of: webView) {
            // WebKit exposes an input context only while its focused frame is
            // editable, including text fields, contenteditable and subframes.
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

/// Webpage arrows go through WebKit's DOM listener; browser chrome is handled
/// here without overriding native text editing or involving other windows.
@MainActor
final class BrowserWindow: NSWindow {
    weak var browserController: BrowserController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isKeyWindow, let controller = browserController,
              attachedSheet == nil, !controller.passwords.isPresented else {
            return super.performKeyEquivalent(with: event)
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
