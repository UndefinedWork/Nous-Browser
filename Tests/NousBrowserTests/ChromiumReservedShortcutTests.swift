import AppKit
import Testing
@testable import NousBrowser

@MainActor private final class ReservedShortcutTarget: NSObject {
    var invocations = 0
    @objc func invoke(_ sender: Any?) { invocations += 1 }
}

@Suite("Chromium browser commands precede web content", .serialized)
@MainActor
struct ChromiumReservedShortcutTests {
    private func event(_ text: String, modifiers: NSEvent.ModifierFlags = .command,
                       type: NSEvent.EventType = .keyDown, keyCode: UInt16 = 0,
                       isRepeat: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: isRepeat, keyCode: keyCode))
    }

    @Test func reservesOnlyTheExistingAddressTabAndNavigationCommands() throws {
        for key in ["l", "L", "t", "n", "w", "r", "[", "]", "1", "5", "9"] {
            #expect(ChromiumReservedBrowserShortcuts.isReserved(try event(key)))
        }
        for key in ["t", "w", "r", "[", "]", "{", "}"] {
            #expect(ChromiumReservedBrowserShortcuts.isReserved(try event(key, modifiers: [.command, .shift])))
        }
        for key in ["a", "c", "v", "x", "z", "k", "p", "f", "g", "0", "=", "-", "\r", "\t"] {
            #expect(!ChromiumReservedBrowserShortcuts.isReserved(try event(key)))
        }
        for modifiers: NSEvent.ModifierFlags in [[], .shift, .control, .option,
            [.command, .control], [.command, .option], [.command, .option, .shift]] {
            #expect(!ChromiumReservedBrowserShortcuts.isReserved(try event("l", modifiers: modifiers)))
        }
        #expect(!ChromiumReservedBrowserShortcuts.isReserved(try event("l", type: .keyUp)))
    }

    @Test func compositionAndTextNavigationKeepTheirOriginalPath() throws {
        for key in ["\r", " ", "\u{1b}", "\u{7f}", "你", "a"] {
            #expect(!ChromiumReservedBrowserShortcuts.isReserved(try event(key, modifiers: [])))
        }
        // Command-arrows depend on editable focus and remain with the existing
        // CEF/native policy. Do not turn a text navigation key into history.
        #expect(!ChromiumReservedBrowserShortcuts.isReserved(try event("\u{f702}", keyCode: 123)))
        #expect(!ChromiumReservedBrowserShortcuts.isReserved(try event("\u{f703}", keyCode: 124)))
        #expect(!ChromiumReservedBrowserShortcuts.isReserved(try event("z", modifiers: [.command, .shift])))
    }

    @Test func sidebarCommandsRequireOnlyCommandAndDispatchTheirOwnMenuAction() throws {
        _ = NSApplication.shared
        let menu = NSMenu(title: "Sidebar commands")
        menu.autoenablesItems = false
        let targets = [ReservedShortcutTarget(), ReservedShortcutTarget()]
        for (index, key) in ["/", "."].enumerated() {
            let item = NSMenuItem(title: index == 0 ? "Toggle Sidebar" : "Hide Sidebar",
                                  action: #selector(ReservedShortcutTarget.invoke(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            item.target = targets[index]
            menu.addItem(item)
            #expect(ChromiumReservedBrowserShortcuts.isReserved(try event(key)))
            #expect(ChromiumReservedBrowserShortcuts.dispatch(try event(key, keyCode: index == 0 ? 44 : 47), through: menu))
            #expect(targets[index].invocations == 1)
            for modifiers: NSEvent.ModifierFlags in [[], .shift, .option, .control,
                [.command, .shift], [.command, .option], [.command, .control],
                [.command, .shift, .option], [.command, .shift, .control],
                [.command, .option, .control], [.command, .shift, .option, .control]] {
                #expect(!ChromiumReservedBrowserShortcuts.isReserved(try event(key, modifiers: modifiers)))
                #expect(!ChromiumReservedBrowserShortcuts.dispatch(try event(key, modifiers: modifiers), through: menu))
            }
            #expect(!ChromiumReservedBrowserShortcuts.isReserved(try event(key, type: .keyUp)))
            #expect(targets[index].invocations == 1)
        }
        #expect(targets[0].invocations == 1)
        #expect(targets[1].invocations == 1)
    }

    @Test func dispatchUsesTheRealMenuActionExactlyOnceWithoutAVisibleWindow() throws {
        _ = NSApplication.shared
        let target = ReservedShortcutTarget()
        let menu = NSMenu(title: "Synthetic browser menu")
        menu.autoenablesItems = false
        let item = NSMenuItem(title: "Address", action: #selector(ReservedShortcutTarget.invoke(_:)), keyEquivalent: "l")
        item.keyEquivalentModifierMask = .command
        item.target = target
        menu.addItem(item)

        #expect(ChromiumReservedBrowserShortcuts.dispatch(try event("l", keyCode: 37), through: menu))
        #expect(target.invocations == 1)
        item.isEnabled = false
        #expect(ChromiumReservedBrowserShortcuts.dispatch(try event("l", keyCode: 37), through: menu))
        #expect(target.invocations == 1)
        #expect(!ChromiumReservedBrowserShortcuts.dispatch(try event("c", keyCode: 8), through: menu))
        #expect(target.invocations == 1)
    }

    @Test func heldNewTabAndWindowKeysDoNotRepeatedlyInvokeTheirRealMenuActions() throws {
        _ = NSApplication.shared
        let menu = NSMenu(title: "Synthetic creation commands")
        menu.autoenablesItems = false
        let target = ReservedShortcutTarget()
        for key in ["t", "n", "w"] {
            let item = NSMenuItem(title: key, action: #selector(ReservedShortcutTarget.invoke(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            item.target = target
            menu.addItem(item)
        }
        for key in ["t", "n"] {
            let before = target.invocations
            #expect(ChromiumReservedBrowserShortcuts.dispatch(try event(key), through: menu))
            for _ in 0..<4 {
                #expect(ChromiumReservedBrowserShortcuts.dispatch(try event(key, isRepeat: true), through: menu))
            }
            #expect(target.invocations == before + 1)
        }
        let beforeClose = target.invocations
        #expect(ChromiumReservedBrowserShortcuts.dispatch(try event("w", isRepeat: true), through: menu))
        #expect(target.invocations == beforeClose + 1)
        #expect(!ChromiumReservedBrowserShortcuts.dispatch(try event("t", modifiers: [], isRepeat: true), through: menu))
        #expect(!ChromiumReservedBrowserShortcuts.dispatch(try event("v", isRepeat: true), through: menu))
        #expect(target.invocations == beforeClose + 1)
    }
}
