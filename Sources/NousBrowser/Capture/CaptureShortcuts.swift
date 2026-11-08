import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// A key plus modifiers, stored as virtual key code and Cocoa modifier bits.
nonisolated struct CaptureShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt16
    var modifiers: UInt

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevant) }
    static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// Global shortcuts need ⌘, ⌥ or ⌃ so ordinary typing is never captured.
    var isValid: Bool { !flags.intersection([.command, .option, .control]).isEmpty }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    /// The menu's key equivalent, when the key has a printable character.
    var keyEquivalent: String? {
        let name = Self.keyName(keyCode)
        guard name.count == 1, let character = name.first, character.isLetter || character.isNumber else { return nil }
        return name.lowercased()
    }

    static func keyName(_ code: UInt16) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: if let name = functionKeys[Int(code)] { return name }
        }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &characters)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// Screenshot and recording shortcuts work everywhere on the Mac (no
/// Accessibility permission: Carbon hot keys). Capture Page is in-app only.
@MainActor
@Observable
final class CaptureShortcuts {
    enum Action: String, CaseIterable, Identifiable, Sendable {
        case screenshot, recording, capturePage
        var id: String { rawValue }

        var title: String {
            switch self {
            case .screenshot: L10n.string("Take Screenshot")
            case .recording: L10n.string("Record Screen")
            case .capturePage: L10n.string("Capture Page")
            }
        }

        var isGlobal: Bool { self != .capturePage }

        var defaultShortcut: CaptureShortcut {
            let modifiers = NSEvent.ModifierFlags([.command, .option, .shift]).rawValue
            switch self {
            case .screenshot: return CaptureShortcut(keyCode: UInt16(kVK_ANSI_S), modifiers: modifiers)
            case .recording: return CaptureShortcut(keyCode: UInt16(kVK_ANSI_R), modifiers: modifiers)
            case .capturePage: return CaptureShortcut(keyCode: UInt16(kVK_ANSI_P), modifiers: modifiers)
            }
        }
    }

    static let shared = CaptureShortcuts()
    static let didChange = Notification.Name("NousCaptureShortcutsDidChange")
    private static let defaultsKey = "NousCaptureShortcuts"

    /// nil means turned off.
    private(set) var shortcuts: [Action: CaptureShortcut?] = [:]
    /// Actions whose shortcut another app already owns.
    private(set) var conflicts: Set<Action> = []
    @ObservationIgnored private var hotKeys: [Action: EventHotKeyRef] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored var perform: (Action) -> Void = { _ in }
    /// While a menu is open, AppKit's menu tracking does not deliver hot key
    /// events; key downs still reach the event dispatcher, so match them there.
    @ObservationIgnored private var menuKeyHandler: EventHandlerRef?
    @ObservationIgnored private weak var trackingMenu: NSMenu?
    @ObservationIgnored private var menuObservers: [NSObjectProtocol] = []

    private init() {
        let saved = (UserDefaults.standard.data(forKey: Self.defaultsKey))
            .flatMap { try? JSONDecoder().decode([String: CaptureShortcut?].self, from: $0) } ?? [:]
        for action in Action.allCases {
            shortcuts[action] = saved.keys.contains(action.rawValue) ? saved[action.rawValue]! : action.defaultShortcut
        }
    }

    func shortcut(_ action: Action) -> CaptureShortcut? { shortcuts[action] ?? nil }

    /// Returns the action that already uses this shortcut, if any.
    func owner(of shortcut: CaptureShortcut, except action: Action) -> Action? {
        Action.allCases.first { $0 != action && self.shortcut($0) == shortcut }
    }

    func set(_ shortcut: CaptureShortcut?, for action: Action) {
        shortcuts[action] = .some(shortcut)
        save()
        register()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func reset(_ action: Action) { set(action.defaultShortcut, for: action) }

    private func save() {
        var stored: [String: CaptureShortcut?] = [:]
        for action in Action.allCases { stored[action.rawValue] = shortcut(action) }
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    /// Hot keys are suspended while a recorder field is listening.
    func suspend(_ suspended: Bool) {
        if suspended { unregisterAll() } else { register() }
    }

    func register() {
        unregisterAll()
        installHandler()
        observeMenus()
        var failed: Set<Action> = []
        for (index, action) in Action.allCases.enumerated() where action.isGlobal {
            guard let shortcut = shortcut(action) else { continue }
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers,
                                             EventHotKeyID(signature: 0x4E4F5553, id: UInt32(index + 1)),
                                             GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { hotKeys[action] = reference } else { failed.insert(action) }
        }
        if failed != conflicts { conflicts = failed }
    }

    private func unregisterAll() {
        hotKeys.values.forEach { UnregisterEventHotKey($0) }
        hotKeys = [:]
    }

    private func observeMenus() {
        guard menuObservers.isEmpty else { return }
        let center = NotificationCenter.default
        menuObservers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated { CaptureShortcuts.shared.menuTracking(began: true, menu: menu) }
        })
        menuObservers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CaptureShortcuts.shared.menuTracking(began: false, menu: nil) }
        })
    }

    private func menuTracking(began: Bool, menu: NSMenu?) {
        if began {
            trackingMenu = menu
            guard menuKeyHandler == nil, !hotKeys.isEmpty else { return }
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventRawKeyDown))
            InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
                var keyCode: UInt32 = 0
                var modifiers: UInt32 = 0
                GetEventParameter(event, EventParamName(kEventParamKeyCode), EventParamType(typeUInt32),
                                  nil, MemoryLayout<UInt32>.size, nil, &keyCode)
                GetEventParameter(event, EventParamName(kEventParamKeyModifiers), EventParamType(typeUInt32),
                                  nil, MemoryLayout<UInt32>.size, nil, &modifiers)
                let handled = MainActor.assumeIsolated {
                    CaptureShortcuts.shared.menuKeyDown(keyCode: keyCode, modifiers: modifiers)
                }
                return handled ? noErr : OSStatus(eventNotHandledErr)
            }, 1, &type, nil, &menuKeyHandler)
        } else {
            trackingMenu = nil
            if let menuKeyHandler { RemoveEventHandler(menuKeyHandler) }
            menuKeyHandler = nil
        }
    }

    private func menuKeyDown(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let mask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        guard let action = Action.allCases.first(where: { action in
            guard action.isGlobal, hotKeys[action] != nil, let shortcut = shortcut(action) else { return false }
            return UInt32(shortcut.keyCode) == keyCode && shortcut.carbonModifiers == modifiers & mask
        }) else { return false }
        // Close the menu first so it is not in the screenshot or recording.
        trackingMenu?.cancelTrackingWithoutAnimation()
        DispatchQueue.main.async { CaptureShortcuts.shared.perform(action) }
        return true
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x4E4F5553 else { return OSStatus(eventNotHandledErr) }
            let index = Int(identifier.id) - 1
            MainActor.assumeIsolated {
                guard CaptureShortcuts.Action.allCases.indices.contains(index) else { return }
                CaptureShortcuts.shared.perform(CaptureShortcuts.Action.allCases[index])
            }
            return noErr
        }, 1, &type, nil, &handler)
    }
}

// MARK: - Settings

struct CaptureShortcutsSettingsView: View {
    @State private var shortcuts = CaptureShortcuts.shared

    var body: some View {
        Form {
            Section {
                ForEach(CaptureShortcuts.Action.allCases) { action in
                    LabeledContent(action.title) {
                        HStack(spacing: 6) {
                            ShortcutRecorder(action: action)
                            Button {
                                withAnimation(BrowserMotion.interaction) { shortcuts.reset(action) }
                            } label: { Image(systemName: "arrow.counterclockwise") }
                                .buttonStyle(.borderless)
                                .help(L10n.string("Reset"))
                                .disabled(shortcuts.shortcut(action) == action.defaultShortcut)
                        }
                    }
                }
            } footer: {
                Text(L10n.string("Screenshot and recording shortcuts work in any app."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, then press the new shortcut. Delete clears it, Escape cancels.
private struct ShortcutRecorder: View {
    let action: CaptureShortcuts.Action
    @State private var shortcuts = CaptureShortcuts.shared
    @State private var recording = false
    @State private var message: String?
    @State private var monitor: Any?

    var body: some View {
        let current = shortcuts.shortcut(action)
        let conflict = shortcuts.conflicts.contains(action)
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? (message ?? L10n.string("Type Shortcut")) : current?.display ?? L10n.string("None"))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(recording ? Color.accentColor : current == nil ? .secondary : .primary)
                .frame(minWidth: 110)
                .padding(.vertical, 4).padding(.horizontal, 10)
                .background(Capsule().fill(Color.primary.opacity(recording ? 0.08 : 0.05)))
                .overlay(Capsule().strokeBorder(recording ? Color.accentColor : conflict ? .orange : .clear, lineWidth: 1))
                .contentTransition(.numericText())
        }
        .buttonStyle(.plain)
        .help(conflict ? L10n.string("Another app is using this shortcut.") : "")
        .animation(BrowserMotion.interaction, value: recording)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        message = nil
        shortcuts.suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        shortcuts.suspend(false)
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(CaptureShortcut.relevant)
        switch Int(event.keyCode) {
        case kVK_Escape where flags.isEmpty: stop(); return
        case kVK_Delete, kVK_ForwardDelete where flags.isEmpty:
            shortcuts.set(nil, for: action); stop(); return
        default: break
        }
        let candidate = CaptureShortcut(keyCode: event.keyCode, modifiers: flags.rawValue)
        guard candidate.isValid else {
            withAnimation { message = L10n.string("Add ⌘, ⌥ or ⌃") }
            NSSound.beep()
            return
        }
        if let other = shortcuts.owner(of: candidate, except: action) {
            withAnimation { message = L10n.format("Used by %@", other.title) }
            NSSound.beep()
            return
        }
        stop()
        shortcuts.set(candidate, for: action)
    }
}
