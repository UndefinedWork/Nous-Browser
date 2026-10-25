import AppKit
import SwiftUI

@main
struct NousBrowserApp: App {
    @NSApplicationDelegateAdaptor(BrowserAppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            BrowserSettingsView(preferences: delegate.windowManager.preferences,
                                appearance: delegate.windowManager.appearance,
                                passwordImporter: delegate.windowManager.passwordImporter)
        }
            .commands { BrowserCommands(windows: delegate.windowManager) }
    }
}

@MainActor
@Observable
final class BrowserController {
    let model: BrowserModel
    let passwords: BrowserPasswordController
    let appearance: BrowserAppearanceSettings
    let preferences: BrowserPreferences
    @ObservationIgnored var onNewWindow: (() -> Void)?
    @ObservationIgnored var onCloseWindow: (() -> Void)?

    init(model: BrowserModel = BrowserModel(), appearance: BrowserAppearanceSettings = BrowserAppearanceSettings(),
         preferences: BrowserPreferences = BrowserPreferences()) {
        self.model = model
        self.appearance = appearance
        self.preferences = preferences
        passwords = BrowserPasswordController(model: model)
    }
    var isAddressPresented = false
    var addressText = ""
    var addressFocusToken = UUID()
    var toast: String?
    private var toastTask: Task<Void, Never>?

    func showAddress() { showAddress(animated: true) }

    func showAddress(animated: Bool) {
        addressText = model.selectedTab?.url?.absoluteString ?? ""
        addressFocusToken = UUID()
        if animated {
            withAnimation(BrowserMotion.spring) { isAddressPresented = true }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { isAddressPresented = true }
        }
    }

    func toggleAddress() {
        if isAddressPresented { dismissAddress() }
        else { showAddress() }
    }

    func dismissAddress() {
        withAnimation(BrowserMotion.spring) { isAddressPresented = false }
        model.selectedTab?.webView.window?.makeFirstResponder(model.selectedTab?.webView)
    }

    func submitAddress() {
        guard !addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard BrowserModel.normalizeAddress(addressText, searchEngine: preferences.searchEngine) != nil else {
            showToast(L10n.string("Enter a valid address or search."))
            return
        }
        model.navigate(addressText, searchEngine: preferences.searchEngine)
        dismissAddress()
    }

    func newTab() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.newTab()
            showAddress(animated: false)
        }
    }

    func newWindow() { onNewWindow?() }
    func closeWindow() { onCloseWindow?() }

    func shutdown() {
        toastTask?.cancel()
        toastTask = nil
        toast = nil
        passwords.dismiss()
        onNewWindow = nil
        onCloseWindow = nil
        model.shutdown()
    }

    func closeTab() {
        guard let id = model.selectedTabID else { return }
        withAnimation(BrowserMotion.spring) { model.closeTab(id) }
    }

    @discardableResult
    func copyURL(_ tab: BrowserTab? = nil, showsToast: Bool = true) -> Bool {
        guard let url = (tab ?? model.selectedTab)?.url else { return false }
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(url.absoluteString, forType: .string)
        if copied && showsToast { showToast(L10n.string("Link Copied")) }
        return copied
    }

    func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(BrowserMotion.spring) { toast = text }
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled, let self else { return }
            withAnimation(BrowserMotion.spring) { self.toast = nil }
        }
    }
}

@MainActor
final class BrowserAppDelegate: NSObject, NSApplicationDelegate {
    let windowManager: BrowserWindowManager = {
        #if DEBUG
        // UI previews use a temporary session, preserving the live browser's tabs.
        let previewPath = ProcessInfo.processInfo.environment["NOUS_BROWSER_PREVIEW_SESSION"]
            ?? Bundle.main.object(forInfoDictionaryKey: "NousBrowserPreviewSessionPath") as? String
        if let path = previewPath {
            return BrowserWindowManager(workspace: BrowserWorkspaceStore(sessionURL: URL(fileURLWithPath: path)))
        }
        // Reopening an isolated preview without its launch environment must
        // never restore or overwrite the user's real tab session.
        if let identifier = Bundle.main.bundleIdentifier, identifier.hasPrefix("com.cellier.nous-browser.") {
            let session = FileManager.default.temporaryDirectory
                .appendingPathComponent("Nous Browser Previews", isDirectory: true)
                .appendingPathComponent(identifier, isDirectory: true)
                .appendingPathComponent("session.json")
            return BrowserWindowManager(workspace: BrowserWorkspaceStore(sessionURL: session))
        }
        #endif
        return BrowserWindowManager(workspace: BrowserWorkspaceStore())
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        windowManager.appearance.apply()
        windowManager.restoreWindows()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windowManager.prepareForTermination()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowManager.prepareForTermination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowManager.showWindow()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        windowManager.open(urls)
    }
}

struct BrowserCommands: Commands {
    @Bindable var windows: BrowserWindowManager
    private var controller: BrowserController? { windows.keyController }
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.string("New Tab")) {
                windows.newTab()
                windows.showWindow()
            }.keyboardShortcut("t")
            Button(L10n.string("New Window")) { windows.newWindow() }.keyboardShortcut("n")
            Button(L10n.string("Open Address…")) { controller?.toggleAddress() }.keyboardShortcut("l")
                .disabled(controller == nil)
        }
        // Replace the native Close group so its ⌘W does not compete with
        // Close Tab while a browser window is active.
        CommandGroup(replacing: .saveItem) {
            Button(L10n.string(controller == nil ? "Close Window" : "Close Tab")) {
                if let controller { controller.closeTab() }
                else { NSApp.keyWindow?.performClose(nil) }
            }.keyboardShortcut("w")
            Button(L10n.string("Close Window")) {
                if controller != nil { windows.closeActiveWindow() }
                else { NSApp.keyWindow?.performClose(nil) }
            }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Button(L10n.string("Reopen Closed Tab")) { controller?.model.restoreClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(controller?.model.canRestoreClosedTab != true)
        }
        CommandMenu(L10n.string("Navigate")) {
            Button(L10n.string("Back")) { controller?.model.goBack() }.keyboardShortcut("[", modifiers: .command)
                .disabled(controller?.model.selectedTab?.canGoBack != true)
            Button(L10n.string("Forward")) { controller?.model.goForward() }.keyboardShortcut("]", modifiers: .command)
                .disabled(controller?.model.selectedTab?.canGoForward != true)
            Button(L10n.string("Reload")) { controller?.model.reload() }.keyboardShortcut("r")
                .disabled(controller == nil)
            Button(L10n.string("Stop Loading")) { controller?.model.stopLoading() }.keyboardShortcut(".")
                .disabled(controller == nil)
            Divider()
            Button(L10n.string("Copy Current Link")) { controller?.copyURL() }.keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(controller?.model.selectedTab?.url == nil)
            Button(L10n.string("Open in Safari")) {
                guard let url = controller?.model.selectedTab?.url else { return }
                NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/Applications/Safari.app"), configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }.disabled(controller?.model.selectedTab?.url == nil)
        }
        CommandMenu(L10n.string("Passwords")) {
            Button(L10n.string("Fill Saved Password…")) { controller?.passwords.presentFill() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(controller?.passwords.canFill != true)
        }
        CommandGroup(after: .sidebar) {
            Button(controller?.model.isSidebarVisible == true ? L10n.string("Hide Sidebar") : L10n.string("Show Sidebar")) {
                withAnimation(BrowserMotion.spring) { controller?.model.toggleSidebar() }
            }.keyboardShortcut("/", modifiers: .command)
                .disabled(controller == nil)
            Divider()
            Button(L10n.string("Next Tab")) { controller?.model.selectNextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(controller == nil)
            Button(L10n.string("Previous Tab")) { controller?.model.selectNextTab(backward: true) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(controller == nil)
        }
        CommandGroup(after: .windowArrangement) {
            Button(L10n.string("Minimize Window")) { windows.activeWindow?.miniaturize(nil) }.keyboardShortcut("m")
                .disabled(controller == nil)
            Button(L10n.string("Zoom Window")) { windows.activeWindow?.zoom(nil) }
                .disabled(controller == nil)
        }
    }
}
