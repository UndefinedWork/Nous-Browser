import AppKit
import CoreGraphics

/// Only the user's current command may open a selector. Returning from System
/// Settings alone must never start a capture.
@MainActor
final class ScreenCapturePermission: NSObject {
    typealias RecoveryPrompt = @MainActor (_ retried: Bool) async -> Bool

    private let preflight: () -> Bool
    private let request: () -> Bool
    private let offerRetry: RecoveryPrompt
    private var hasPendingCommand = false

    init(preflight: @escaping () -> Bool = CGPreflightScreenCaptureAccess,
         request: @escaping () -> Bool = CGRequestScreenCaptureAccess,
         offerRetry: @escaping RecoveryPrompt = ScreenCapturePermission.offerSettings) {
        self.preflight = preflight
        self.request = request
        self.offerRetry = offerRetry
    }

    func perform(afterDenial: Bool = false, _ openSelector: @escaping @MainActor () -> Void) {
        guard !hasPendingCommand else { return }
        if !afterDenial, preflight() {
            openSelector()
            return
        }
        hasPendingCommand = true
        // Leave menu tracking before displaying the system prompt.
        Task { @MainActor in
            var allowed = !afterDenial && (request() || preflight())
            var retried = false
            while !allowed {
                guard await offerRetry(retried) else {
                    hasPendingCommand = false
                    return
                }
                allowed = preflight()
                retried = true
            }
            hasPendingCommand = false
            openSelector()
        }
    }

    static func offerSettings(retried: Bool) async -> Bool {
        let alert = NSAlert()
        alert.messageText = retried ? L10n.string("Screen Capture Is Still Unavailable") : L10n.string("Allow Screen Capture")
        alert.informativeText = retried
            ? L10n.string("If Nous Browser is already on in Screen & System Audio Recording, turn it off and on again. Follow any prompt to quit and reopen Nous Browser, then try the capture again.")
            : L10n.string("Turn on Nous Browser in System Settings → Privacy & Security → Screen & System Audio Recording. If macOS asks you to quit and reopen Nous Browser, do so, then try the capture again.")
        let settings = alert.addButton(withTitle: L10n.string("Open System Settings"))
        // Opening Settings leaves the sheet in place so the user can retry or cancel on return.
        settings.target = ScreenCapturePermission.self
        settings.action = #selector(openSettings(_:))
        alert.addButton(withTitle: L10n.string("Try Again"))
        alert.addButton(withTitle: L10n.string("Cancel")).keyEquivalent = "\u{1b}"
        NSApp.activate()
        let window = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow ?? NSApp.mainWindow
        if let window, window.isVisible {
            return await alert.beginSheetModal(for: window) == .alertSecondButtonReturn
        }
        // A global capture shortcut also works when all browser windows are closed.
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private static func openSettings(_ sender: NSButton) {
        let workspace = NSWorkspace.shared
        let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        if !workspace.open(pane), let settings = workspace.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            workspace.openApplication(at: settings, configuration: .init())
        }
    }
}
