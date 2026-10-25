import AppKit
import Testing
import WebKit
@testable import NousBrowser

@Suite("Navigation arrows preserve text editing", .serialized)
@MainActor
struct BrowserNavigationShortcutTests {
    private func event(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = .command,
                       type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        let character = keyCode == 123 ? "\u{F702}" : keyCode == 124 ? "\u{F703}" : "x"
        return try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           characters: character, charactersIgnoringModifiers: character,
                                           isARepeat: false, keyCode: keyCode))
    }

    private func withWindow(_ body: (NSWindow, WKWebView, NSView) throws -> Void) rethrows {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: host.bounds, configuration: configuration)
        host.addSubview(webView)
        window.contentView = host
        defer {
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        // No orderFront/activation or page load: these are synchronous AppKit
        // focus tests, separate from the real browser's visible-page QA.
        try body(window, webView, host)
    }

    @Test func commandLeftAndRightMapToTheExpectedHistoryDirection() throws {
        #expect(BrowserNavigationShortcuts.direction(for: try event(keyCode: 123)) == .back)
        #expect(BrowserNavigationShortcuts.direction(for: try event(keyCode: 124)) == .forward)
    }

    @Test func onlyCommandIsAcceptedAmongSemanticModifiers() throws {
        let modifiers: [NSEvent.ModifierFlags] = [.command, .shift, .control, .option]
        for bits in 0..<16 {
            var flags: NSEvent.ModifierFlags = []
            for (index, modifier) in modifiers.enumerated() where bits & (1 << index) != 0 {
                flags.insert(modifier)
            }
            let left = try event(keyCode: 123, modifiers: flags)
            let right = try event(keyCode: 124, modifiers: flags)
            #expect(BrowserNavigationShortcuts.direction(for: left) == (flags == .command ? .back : nil))
            #expect(BrowserNavigationShortcuts.direction(for: right) == (flags == .command ? .forward : nil))
        }
    }

    @Test func arrowHardwareAndCapsLockFlagsDoNotDisableNavigation() throws {
        let additionalFlags: [NSEvent.ModifierFlags] = [
            .capsLock, .function, .numericPad, [.capsLock, .function, .numericPad]
        ]
        for additional in additionalFlags {
            #expect(BrowserNavigationShortcuts.direction(for: try event(keyCode: 123, modifiers: [.command, additional])) == .back)
            #expect(BrowserNavigationShortcuts.direction(for: try event(keyCode: 124, modifiers: [.command, additional])) == .forward)
        }
    }

    @Test func keyUpAndOtherKeysCannotNavigate() throws {
        for keyCode in [123, 124] as [UInt16] {
            #expect(BrowserNavigationShortcuts.direction(for: try event(keyCode: keyCode, type: .keyUp)) == nil)
        }
        for keyCode in [0, 53, 115, 116, 119, 121, 125, 126] as [UInt16] {
            #expect(BrowserNavigationShortcuts.direction(for: try event(keyCode: keyCode)) == nil)
        }
    }

    @Test func editableNativeTextKeepsItsLineNavigation() {
        withWindow { window, webView, host in
            let editor = NSTextView(frame: NSRect(x: 10, y: 10, width: 300, height: 80))
            editor.string = "Synthetic first line\nSynthetic second line"
            editor.isEditable = true
            editor.isSelectable = true
            host.addSubview(editor)
            #expect(window.makeFirstResponder(editor))
            #expect(window.firstResponder === editor)
            #expect(BrowserNavigationShortcuts.shouldPreserveTextEditing(in: window, webView: webView))
        }
    }

    @Test func selectableReadOnlyNativeTextAlsoKeepsLineNavigation() {
        withWindow { window, webView, host in
            let editor = NSTextView(frame: NSRect(x: 10, y: 10, width: 300, height: 80))
            editor.string = "Synthetic selectable text"
            editor.isEditable = false
            editor.isSelectable = true
            host.addSubview(editor)
            #expect(window.makeFirstResponder(editor))
            #expect(window.firstResponder === editor)
            #expect(BrowserNavigationShortcuts.shouldPreserveTextEditing(in: window, webView: webView))
        }
    }

    @Test func aNativeTextFieldsActualFieldEditorIsProtected() throws {
        try withWindow { window, webView, host in
            let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 300, height: 24))
            field.stringValue = "https://synthetic.example.test/path"
            field.isEditable = true
            host.addSubview(field)
            #expect(window.makeFirstResponder(field))
            field.selectText(nil)
            let editor = try #require(window.firstResponder as? NSTextView)
            #expect(editor.isFieldEditor)
            #expect(BrowserNavigationShortcuts.shouldPreserveTextEditing(in: window, webView: webView))
        }
    }

    @Test func leavingAnEditorDoesNotKeepAnUnrelatedViewInEditingMode() {
        withWindow { window, webView, host in
            let editor = NSTextView(frame: NSRect(x: 10, y: 10, width: 300, height: 80))
            host.addSubview(editor)
            #expect(window.makeFirstResponder(editor))
            #expect(BrowserNavigationShortcuts.shouldPreserveTextEditing(in: window, webView: webView))
            let passive = FocusableView(frame: host.bounds)
            host.addSubview(passive)
            #expect(window.makeFirstResponder(passive))
            #expect(!BrowserNavigationShortcuts.shouldPreserveTextEditing(in: window, webView: webView))
        }
    }

    @Test func anUnloadedNonEditingWebViewDoesNotBlockNavigation() {
        withWindow { window, webView, _ in
            #expect(window.makeFirstResponder(webView))
            #expect(window.firstResponder === webView)
            #expect(webView.inputContext == nil)
            #expect(!BrowserNavigationShortcuts.shouldPreserveTextEditing(in: window, webView: webView))
        }
    }

    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }
}
