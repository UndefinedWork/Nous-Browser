import AppKit

/// Recovery after ScreenCaptureKit explicitly denies a recording.
@MainActor
final class ScreenCapturePermission {
    private let presentPrompt: @MainActor () async -> Bool
    private let openSettings: @MainActor () -> Void
    private(set) var isPresenting = false

    init(presentPrompt: @escaping @MainActor () async -> Bool = ScreenCapturePermission.presentSettingsPrompt,
         openSettings: @escaping @MainActor () -> Void = ScreenCapturePermission.openScreenRecordingSettings) {
        self.presentPrompt = presentPrompt
        self.openSettings = openSettings
    }

    func offerSettingsAfterDenial() {
        guard !isPresenting else { return }
        isPresenting = true
        Task { @MainActor in
            let choseSettings = await presentPrompt()
            isPresenting = false
            if choseSettings { openSettings() }
        }
    }

    private static func presentSettingsPrompt() async -> Bool {
        // The system consent panel can take the user directly to Settings.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.systempreferences" else { return false }
        let alert = NSAlert()
        alert.messageText = L10n.string("Allow Screen Capture")
        alert.informativeText = L10n.string("macOS did not allow this recording. You can review screen recording access for Nous Browser in System Settings.")
        alert.addButton(withTitle: L10n.string("Open System Settings"))
        alert.addButton(withTitle: L10n.string("Cancel")).keyEquivalent = "\u{1b}"
        NSApp.activate()
        let window = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow ?? NSApp.mainWindow
        if let window, window.isVisible {
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func openScreenRecordingSettings() {
        let workspace = NSWorkspace.shared
        let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        if !workspace.open(pane), let settings = workspace.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            workspace.openApplication(at: settings, configuration: .init())
        }
    }
}
