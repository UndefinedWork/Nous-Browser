import AppKit
import SwiftUI

@main
struct NousBrowserApp: App {
    @NSApplicationDelegateAdaptor(BrowserAppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands { BrowserCommands(controller: delegate.controller) }
    }
}

@MainActor
@Observable
final class BrowserController {
    let model: BrowserModel
    let passwords: BrowserPasswordController
    let appearance = BrowserAppearanceSettings()

    init(model: BrowserModel = BrowserModel()) {
        self.model = model
        passwords = BrowserPasswordController(model: model)
    }
    var isAddressPresented = false
    var addressText = ""
    var addressFocusToken = UUID()
    var toast: String?
    private var toastTask: Task<Void, Never>?

    func showAddress() {
        addressText = model.selectedTab?.url?.absoluteString ?? ""
        addressFocusToken = UUID()
        withAnimation(BrowserMotion.spring) { isAddressPresented = true }
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
        guard BrowserModel.normalizeAddress(addressText) != nil else {
            showToast(L10n.string("Enter a valid address or search."))
            return
        }
        model.navigate(addressText)
        dismissAddress()
    }

    func newTab() {
        withAnimation(BrowserMotion.spring) { model.newTab() }
        showAddress()
    }

    func closeTab() {
        guard let id = model.selectedTabID else { return }
        withAnimation(BrowserMotion.spring) { model.closeTab(id) }
    }

    func copyURL(_ tab: BrowserTab? = nil) {
        guard let url = (tab ?? model.selectedTab)?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        showToast(L10n.string("Link Copied"))
    }

    func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(BrowserMotion.spring) { toast = text }
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(BrowserMotion.spring) { toast = nil }
        }
    }
}

@MainActor
final class BrowserAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let controller: BrowserController = {
        #if DEBUG
        // UI previews use a temporary session, preserving the live browser's tabs.
        let previewPath = ProcessInfo.processInfo.environment["NOUS_BROWSER_PREVIEW_SESSION"]
            ?? Bundle.main.object(forInfoDictionaryKey: "NousBrowserPreviewSessionPath") as? String
        if let path = previewPath {
            return BrowserController(model: BrowserModel(sessionURL: URL(fileURLWithPath: path)))
        }
        // Reopening an isolated preview without its launch environment must
        // never restore or overwrite the user's real tab session.
        if let identifier = Bundle.main.bundleIdentifier, identifier.hasPrefix("com.cellier.nous-browser.") {
            let session = FileManager.default.temporaryDirectory
                .appendingPathComponent("Nous Browser Previews", isDirectory: true)
                .appendingPathComponent(identifier, isDirectory: true)
                .appendingPathComponent("session.json")
            return BrowserController(model: BrowserModel(sessionURL: session))
        }
        #endif
        return BrowserController()
    }()
    private var mainWindow: NSWindow?
    private lazy var hibernationMonitor = TabHibernationMonitor(model: controller.model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        controller.appearance.apply()
        showWindow()
        hibernationMonitor.start()
    }

    func showWindow() {
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Nous Browser"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // AppKit sometimes treated a tab row as window background and moved the
        // window instead of the tab. Empty areas opt in with windowDragBackground().
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 540, height: 400)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        [.closeButton, .miniaturizeButton, .zoomButton].forEach {
            window.standardWindowButton($0)?.isHidden = true
        }
        window.delegate = self
        window.contentView = NSHostingView(rootView: BrowserShell(controller: controller))
        window.setFrameAutosaveName("NousBrowserMainWindow")
        if !window.setFrameUsingName("NousBrowserMainWindow") { window.center() }
        mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.model.persistSession()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        showWindow()
        for url in urls where BrowserModel.canOpenExternalURL(url) {
            controller.model.newTab(url: url)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        [.closeButton, .miniaturizeButton, .zoomButton].forEach {
            window.standardWindowButton($0)?.isHidden = true
        }
    }
}

struct BrowserCommands: Commands {
    let controller: BrowserController
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.string("New Tab"), action: controller.newTab).keyboardShortcut("t")
            Button(L10n.string("Open Address…"), action: controller.toggleAddress).keyboardShortcut("l")
            Divider()
            Button(L10n.string("Close Tab"), action: controller.closeTab).keyboardShortcut("w")
            Button(L10n.string("Reopen Closed Tab")) { controller.model.restoreClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }
        CommandMenu(L10n.string("Navigate")) {
            Button(L10n.string("Back")) { controller.model.goBack() }.keyboardShortcut("[", modifiers: .command)
                .disabled(controller.model.selectedTab?.canGoBack != true)
            Button(L10n.string("Forward")) { controller.model.goForward() }.keyboardShortcut("]", modifiers: .command)
                .disabled(controller.model.selectedTab?.canGoForward != true)
            Button(L10n.string("Reload")) { controller.model.reload() }.keyboardShortcut("r")
            Button(L10n.string("Stop Loading")) { controller.model.stopLoading() }.keyboardShortcut(".")
            Divider()
            Button(L10n.string("Copy Current Link")) { controller.copyURL() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button(L10n.string("Open in Safari")) {
                guard let url = controller.model.selectedTab?.url else { return }
                NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/Applications/Safari.app"), configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
        }
        CommandMenu(L10n.string("Passwords")) {
            Button(L10n.string("Fill Saved Password…"), action: controller.passwords.presentFill)
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!controller.passwords.canFill)
            Button(L10n.string("Import Passwords…"), action: controller.passwords.presentImport)
        }
        CommandGroup(after: .sidebar) {
            Menu(L10n.string("Appearance")) {
                Picker(L10n.string("Appearance"), selection: Binding(
                    get: { controller.appearance.mode },
                    set: { controller.appearance.select($0) }
                )) {
                    ForEach(BrowserAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }.pickerStyle(.inline)
            }
            Divider()
            Button(controller.model.isSidebarVisible ? L10n.string("Hide Sidebar") : L10n.string("Show Sidebar")) {
                withAnimation(BrowserMotion.spring) { controller.model.toggleSidebar() }
            }.keyboardShortcut("/", modifiers: .command)
            Divider()
            Button(L10n.string("Next Tab")) { controller.model.selectNextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button(L10n.string("Previous Tab")) { controller.model.selectNextTab(backward: true) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
        CommandGroup(after: .windowArrangement) {
            Button(L10n.string("Minimize Window")) { NSApp.keyWindow?.miniaturize(nil) }.keyboardShortcut("m")
            Button(L10n.string("Zoom Window")) { NSApp.keyWindow?.zoom(nil) }
        }
    }
}
