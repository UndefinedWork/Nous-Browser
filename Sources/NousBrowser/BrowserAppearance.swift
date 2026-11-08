import AppKit
import Observation

nonisolated enum BrowserAppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String {
        let key = switch self {
        case .system: "Follow System"
        case .light: "Light"
        case .dark: "Dark"
        }
        return L10n.string(key)
    }
}

/// One app-level override keeps SwiftUI, Chromium, sheets and native panels in
/// the same appearance. Nil leaves AppKit's live system inheritance intact.
@MainActor
@Observable
final class BrowserAppearanceSettings {
    private(set) var mode: BrowserAppearanceMode
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "browser.appearance"
    private static let windowButtonsKey = "browser.showsWindowButtons"

    /// Close / minimize / zoom in the sidebar. Off by default; never shown
    /// while the sidebar is hidden.
    var showsWindowButtons: Bool {
        didSet { defaults.set(showsWindowButtons, forKey: Self.windowButtonsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.key).flatMap(BrowserAppearanceMode.init(rawValue:)) ?? .system
        showsWindowButtons = defaults.bool(forKey: Self.windowButtonsKey)
    }

    func select(_ mode: BrowserAppearanceMode) {
        self.mode = mode
        if mode == .system { defaults.removeObject(forKey: Self.key) }
        else { defaults.set(mode.rawValue, forKey: Self.key) }
        apply()
    }

    func apply() {
        NSApplication.shared.appearance = switch mode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
