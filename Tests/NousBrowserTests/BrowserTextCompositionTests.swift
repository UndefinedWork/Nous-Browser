import AppKit
import SwiftUI
import Testing
@testable import NousBrowser

/// These use AppKit's actual NSTextField field editor and text-input-client
/// methods. They cover our native chrome integration, not a physical IME's
/// handling of a hardware Return event or a webpage's composition events.
@Suite("Native browser text composition", .serialized)
@MainActor
struct BrowserTextCompositionTests {
    @MainActor private final class State {
        var text = ""
        var submitted: [String] = []
        var cancelled = 0
        var movements: [Int] = []
        var next = 0
        var previous = 0
        let focusToken = UUID()
        var binding: Binding<String> {
            Binding(get: { self.text }, set: { self.text = $0 })
        }
    }

    @MainActor private final class Fixture<Content: View> {
        let window: NSWindow
        let host: NSHostingView<Content>
        let content: () -> Content
        let field: NSTextField
        let editor: NSTextView

        init(content: @escaping () -> Content) async throws {
            _ = NSApplication.shared
            self.content = content
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: content())
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            // Let the production viewDidMoveToWindow focus callback finish
            // before establishing the test's marked text.
            try await Task.sleep(for: .milliseconds(30))
            field = try #require(Self.textField(in: host))
            #expect(window.makeFirstResponder(field))
            field.selectText(nil)
            editor = try #require(window.firstResponder as? NSTextView)
            #expect(editor.isFieldEditor)
        }

        private static func textField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField { return field }
            return view.subviews.lazy.compactMap { textField(in: $0) }.first
        }

        func beginComposition() {
            editor.setMarkedText("yingwen", selectedRange: NSRange(location: 7, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(editor.hasMarkedText())
            #expect(editor.string == "yingwen")
        }

        func refresh() async throws {
            host.rootView = content()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }

        func commit() {
            editor.insertText("yingwen", replacementRange: editor.markedRange())
            #expect(!editor.hasMarkedText())
            #expect(editor.string == "yingwen")
        }

        func close() {
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
    }

    private func address(_ state: State) async throws -> Fixture<AddressInput> {
        try await Fixture {
            AddressInput(text: state.binding, submit: { state.submitted.append(state.text) },
                         cancel: { state.cancelled += 1 }, move: { state.movements.append($0) })
        }
    }

    private func find(_ state: State) async throws -> Fixture<PageFindInput> {
        try await Fixture {
            PageFindInput(text: state.binding, focusToken: state.focusToken,
                          next: { state.next += 1 }, previous: { state.previous += 1 },
                          cancel: { state.cancelled += 1 })
        }
    }

    @Test func addressRefreshPreservesMarkedTextAndSelection() async throws {
        let state = State()
        let fixture = try await address(state)
        defer { fixture.close() }
        fixture.beginComposition()
        let markedRange = fixture.editor.markedRange()
        let selection = fixture.editor.selectedRange()
        try await fixture.refresh()
        #expect(fixture.editor.hasMarkedText())
        #expect(fixture.editor.markedRange() == markedRange)
        #expect(fixture.editor.selectedRange() == selection)
        #expect(fixture.editor.string == "yingwen")
        #expect(state.submitted.isEmpty)
    }

    @Test func findRefreshPreservesMarkedTextAndSelection() async throws {
        let state = State()
        let fixture = try await find(state)
        defer { fixture.close() }
        fixture.beginComposition()
        let markedRange = fixture.editor.markedRange()
        let selection = fixture.editor.selectedRange()
        try await fixture.refresh()
        #expect(fixture.editor.hasMarkedText())
        #expect(fixture.editor.markedRange() == markedRange)
        #expect(fixture.editor.selectedRange() == selection)
        #expect(fixture.editor.string == "yingwen")
        #expect(state.next == 0)
    }

    @Test func addressEditorChangeNotificationUpdatesBindingWithoutEndingComposition() async throws {
        let state = State()
        let fixture = try await address(state)
        defer { fixture.close() }
        fixture.beginComposition()
        // NSTextView's public notification path, rather than assigning the
        // SwiftUI binding or directly invoking our NSTextField delegate.
        fixture.editor.didChangeText()
        #expect(state.text == "yingwen")
        #expect(fixture.editor.hasMarkedText())
        try await fixture.refresh()
        #expect(fixture.editor.hasMarkedText())
        #expect(fixture.editor.string == "yingwen")
        fixture.commit()
        #expect(state.text == "yingwen")
    }

    @Test func findEditorChangeNotificationUpdatesBindingWithoutEndingComposition() async throws {
        let state = State()
        let fixture = try await find(state)
        defer { fixture.close() }
        fixture.beginComposition()
        fixture.editor.didChangeText()
        #expect(state.text == "yingwen")
        #expect(fixture.editor.hasMarkedText())
        try await fixture.refresh()
        #expect(fixture.editor.hasMarkedText())
        #expect(fixture.editor.string == "yingwen")
        fixture.commit()
        #expect(state.text == "yingwen")
    }

    @Test func markedAddressReturnDoesNotSubmitThroughFieldEditorCommandRoute() async throws {
        let state = State()
        let fixture = try await address(state)
        defer { fixture.close() }
        fixture.beginComposition()
        fixture.editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(state.submitted.isEmpty)
        #expect(state.cancelled == 0)
        #expect(state.movements.isEmpty)
    }

    @Test func markedFindReturnDoesNotAdvanceThroughFieldEditorCommandRoute() async throws {
        let state = State()
        let fixture = try await find(state)
        defer { fixture.close() }
        fixture.beginComposition()
        fixture.editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(state.next == 0)
        #expect(state.previous == 0)
        #expect(state.cancelled == 0)
    }

    @Test func markedAddressCandidateCommandsDoNotDismissOrMoveSuggestions() async throws {
        for command in ["cancelOperation:", "moveUp:", "moveDown:"] {
            let state = State()
            let fixture = try await address(state)
            defer { fixture.close() }
            fixture.beginComposition()
            fixture.editor.doCommand(by: NSSelectorFromString(command))
            #expect(state.submitted.isEmpty)
            #expect(state.cancelled == 0)
            #expect(state.movements.isEmpty)
        }
    }

    @Test func markedFindEscapeDoesNotDismissTheBrowserFindBar() async throws {
        let state = State()
        let fixture = try await find(state)
        defer { fixture.close() }
        fixture.beginComposition()
        fixture.editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(state.cancelled == 0)
        #expect(state.next == 0)
        #expect(state.previous == 0)
    }

    @Test func committedAddressReturnSubmitsExactlyOnceWithCommittedText() async throws {
        let state = State()
        let fixture = try await address(state)
        defer { fixture.close() }
        fixture.beginComposition()
        fixture.commit()
        fixture.editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(state.submitted == ["yingwen"])
        #expect(!fixture.editor.string.contains("\n"))
    }

    @Test func committedFindReturnAdvancesExactlyOnce() async throws {
        let state = State()
        let fixture = try await find(state)
        defer { fixture.close() }
        fixture.beginComposition()
        fixture.commit()
        fixture.editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(state.text == "yingwen")
        #expect(state.next == 1)
        #expect(state.previous == 0)
        #expect(!fixture.editor.string.contains("\n"))
    }
}
