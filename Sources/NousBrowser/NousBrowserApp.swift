import AppKit
import SwiftUI
import NousCore
import CryptoKit

/// Dia-style startup: Chromium's real //chrome browser process (inside
/// NousCore.framework) owns NSApp and the main run loop. The Swift UI is
/// installed from NousBrowserApplication's delegate once the default profile
/// is ready. There is no CEF layer and no external message pump.
@main
struct NousBrowserLauncher {
    @MainActor
    static func main() {
        do {
            guard try BrowserInstanceLock.start() else {
                if let identifier = Bundle.main.bundleIdentifier {
                    NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                        .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?
                        .activate(options: [])
                }
                return
            }
            try BrowserPreviewCredentialPolicy.startIfNeeded()
        } catch {
            BrowserPreviewCredentialPolicy.finish()
            let alert = NSAlert()
            alert.messageText = L10n.string("Unable to Start")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        guard let storage = ChromiumStorageIdentity.current() else {
            BrowserPreviewCredentialPolicy.finish()
            let alert = NSAlert()
            alert.messageText = L10n.string("Unable to Start")
            alert.informativeText = L10n.string("The browser build could not be identified.")
            alert.runModal()
            return
        }
        // Their Safe Storage keys were tied to one build each and are unreadable now.
        if storage.safeStoragePassword != nil { ChromiumStorageIdentity.removeLegacyBuildProfiles() }
        try? FileManager.default.createDirectory(at: storage.profile, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let host = NousApplicationHost()
        let configuration = NousBrowserApplicationConfiguration()
        configuration.userDataDirectory = storage.profile.path
        configuration.keychainServiceName = storage.keychainService
        configuration.keychainAccountName = storage.keychainAccount
        configuration.safeStoragePassword = storage.safeStoragePassword
        // FedCM ("Sign in with Google" account chooser) needs Chrome's own
        // browser-window bubble, which Nous does not have: the button did
        // nothing. Without it, Google Identity Services opens its popup instead.
        configuration.additionalArguments = ["--disable-features=FedCm"]
        let application = NousBrowserApplication.shared()
        application.delegate = host
        // Blocks inside ChromeMain until Chromium has shut down.
        let code = withExtendedLifetime(host) { application.run(with: configuration) }
        BrowserPreviewCredentialPolicy.finish()
        exit(code)
    }
}

/// One Chromium profile per distribution that every update reopens.
/// Team-signed builds keep Chromium's Safe Storage secret in the keychain;
/// ad-hoc builds (whose keychain access is tied to one build's code hash)
/// derive it from `NousLocalSecret`, so no keychain item is read or created.
struct ChromiumStorageIdentity {
    let profile: URL
    let keychainService: String
    let keychainAccount: String
    let safeStoragePassword: String?

    static func current() -> ChromiumStorageIdentity? {
        let paths = BrowserRuntimePaths.current
        let production = paths.distribution == .production
        let service = production ? "Nous Browser Safe Storage" : "Nous Browser Preview Safe Storage"
        let account = production ? "Nous Browser" : "Nous Browser Preview"
        if NousStableSigning.verifiedTeam() != nil {
            return ChromiumStorageIdentity(
                profile: paths.chromiumProfileDirectory
                    .appendingPathComponent(production ? "Stable/GitHub" : "Stable/Preview", isDirectory: true),
                keychainService: service, keychainAccount: account, safeStoragePassword: nil)
        }
        guard let secret = try? NousLocalSecret.load(in: paths.directory) else { return nil }
        return ChromiumStorageIdentity(
            profile: paths.chromiumProfileDirectory
                .appendingPathComponent(production ? "Local/GitHub" : "Local/Preview", isDirectory: true),
            keychainService: service, keychainAccount: account,
            safeStoragePassword: NousLocalSecret.chromiumPassword(secret))
    }

    /// Per-build profiles from releases before the shared local key.
    static func removeLegacyBuildProfiles() {
        let root = BrowserRuntimePaths.current.chromiumProfileDirectory
        for name in ["IsolatedBuilds", "PreviewBuilds"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }
}

/// NousBrowserApplicationDelegate: installs the AppKit app delegate and menu.
@MainActor
final class NousApplicationHost: NSObject, NousBrowserApplicationDelegate {
    private let appDelegate = BrowserAppDelegate()
    private var mainMenu: BrowserMainMenu?

    func browserApplicationDidInitialize(_ application: NousBrowserApplication) {
        NSApp.delegate = appDelegate
        let menu = BrowserMainMenu(delegate: appDelegate)
        mainMenu = menu
        NSApp.mainMenu = menu.menu
        NSApp.servicesMenu = menu.servicesMenu
        NSApp.windowsMenu = menu.windowsMenu
        NSApp.helpMenu = menu.helpMenu
    }

    func browserApplicationWillShutDown(_ application: NousBrowserApplication) {
        appDelegate.chromiumWillShutDown()
    }
}

@MainActor
@Observable
final class BrowserController {
    let model: BrowserModel
    let passwords: BrowserPasswordController
    let appearance: BrowserAppearanceSettings
    let preferences: BrowserPreferences
    let history: BrowserHistoryStore
    let find: BrowserPageFindController
    @ObservationIgnored var onNewWindow: (() -> Void)?
    @ObservationIgnored var onCloseWindow: (() -> Void)?
    @ObservationIgnored var onMoveTabToNewWindow: ((UUID, NSPoint) -> Bool)?
    @ObservationIgnored var onMoveTabToWindow: ((UUID, BrowserController, Int) -> Bool)?
    @ObservationIgnored var tabDragCoordinator: BrowserTabDragCoordinator?

    init(model: BrowserModel = BrowserModel(), appearance: BrowserAppearanceSettings = BrowserAppearanceSettings(),
         preferences: BrowserPreferences = BrowserPreferences(), history: BrowserHistoryStore? = nil) {
        self.model = model
        find = BrowserPageFindController(model: model)
        self.appearance = appearance
        self.preferences = preferences
        self.history = history ?? BrowserHistoryStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("Nous Browser Standalone", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("history.json"))
        passwords = BrowserPasswordController(model: model)
        model.searchEngineProvider = { [weak preferences] in preferences?.searchEngine ?? .google }
    }
    var isAddressPresented = false
    var addressText = ""
    var addressFocusToken = UUID()
    var toast: String?
    private var toastTask: Task<Void, Never>?

    func showAddress() { showAddress(animated: true) }

    func showAddress(animated: Bool) {
        find.dismiss()
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

    func moveTabToNewWindow(_ id: UUID, at point: NSPoint) -> Bool {
        onMoveTabToNewWindow?(id, point) ?? false
    }

    func moveTab(_ id: UUID, to target: BrowserController, at index: Int) -> Bool {
        onMoveTabToWindow?(id, target, index) ?? false
    }

    func selectNextTab(backward: Bool = false) {
        if isAddressPresented { dismissAddress() }
        model.selectNextTab(backward: backward)
    }

    func selectTab(number: Int) {
        if isAddressPresented { dismissAddress() }
        model.selectTab(number: number)
    }

    func showFind() {
        if isAddressPresented { dismissAddress() }
        find.present()
    }

    func shutdown() {
        find.shutdown()
        toastTask?.cancel()
        toastTask = nil
        toast = nil
        passwords.dismiss()
        onNewWindow = nil
        onCloseWindow = nil
        onMoveTabToNewWindow = nil
        onMoveTabToWindow = nil
        tabDragCoordinator?.unregister(self)
        tabDragCoordinator = nil
        model.shutdown()
    }

    func closeTab() {
        // Nothing selected (the start page with only pins left): ⌘W closes the window.
        guard let id = model.selectedTabID else { onCloseWindow?(); return }
        // A blank new tab cannot refuse to close; its palette goes with it at once.
        if isAddressPresented, model.selectedTab?.hasWebContent == false { dismissAddress() }
        let focusToken = addressFocusToken
        model.requestTabClose(id) { [weak self] accepted in
            guard let self, accepted, self.addressFocusToken == focusToken else { return }
            if self.isAddressPresented { self.dismissAddress() }
        }
    }

    @discardableResult
    func copyURL(_ tab: BrowserTab? = nil, showsToast: Bool = true) -> Bool {
        guard let url = (tab ?? model.selectedTab)?.url else { return false }
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(url.absoluteString, forType: .string)
        if copied && showsToast { showToast(L10n.string("Link Copied")) }
        return copied
    }

    /// ⌘D: bookmark the page in a tab (the current one by default), or remove it.
    func toggleBookmark(_ tab: BrowserTab? = nil) {
        guard let tab = tab ?? model.selectedTab, tab.hasWebContent, let url = tab.url else { return }
        let added = LibraryStore.shared.toggleBookmark(url: url, title: tab.displayTitle)
        showToast(L10n.string(added ? "Bookmarked" : "Bookmark Removed"))
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
    private var chromiumTerminationPending = false
    lazy var automation = BrowserAutomationService(windows: windowManager,
        socketPath: BrowserRuntimePaths.current.automationSocketPath)

    let windowManager: BrowserWindowManager = {
        let paths = BrowserRuntimePaths.current
        // Only the explicitly isolated preview may select a temporary QA session.
        // Environment variables must not redirect an installed production session.
        return BrowserWindowManager(workspace: BrowserWorkspaceStore(sessionURL: paths.sessionURL(
            qaOverride: ProcessInfo.processInfo.environment["NOUS_BROWSER_PREVIEW_SESSION"])))
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        BrowserServiceMenuFilter.install()
        ChromiumDownloadCoordinator.shared.start()
        windowManager.appearance.apply()
        windowManager.restoreWindows()
        NBChromiumRuntime.setTerminationHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.requestChromiumTermination()
            }
        }
        LibraryStore.shared.start(history: windowManager.history)
        CaptureShortcuts.shared.perform = { [weak self] action in
            switch action {
            case .screenshot: CaptureCoordinator.shared.takeScreenshot()
            case .recording: CaptureCoordinator.shared.toggleRecording()
            case .capturePage: CaptureCoordinator.shared.capturePage(self?.windowManager.activeContext?.controller.model.selectedTab)
            }
        }
        CaptureShortcuts.shared.register()
        CaptureCoordinator.shared.openPage = { [weak self] page in
            guard let self else { return }
            // A tab in the window in front of the user; a window only when none is open.
            if self.windowManager.activeController == nil { self.windowManager.newWindow() }
            guard let context = self.windowManager.visibleContext else { return }
            context.controller.dismissAddress()
            context.controller.model.openNativePage(page)
            self.windowManager.activate(context)
        }
        CaptureCoordinator.shared.report = { [weak self] message in
            if let controller = self?.windowManager.activeController { controller.showToast(message) }
            else { let alert = NSAlert(); alert.messageText = message; alert.runModal() }
        }
        ChromiumSmokeCheck.run(windowManager: windowManager)
        automation.startIfEnabled()
        BrowserUpdater.shared.start()
    }

    private func requestChromiumTermination() {
        Self.trace("termination: requested (pending=\(chromiumTerminationPending))")
        guard !chromiumTerminationPending else { return }
        chromiumTerminationPending = true
        ChromiumDownloadCoordinator.shared.confirmTermination { [weak self] accepted in
            Self.trace("termination: downloads accepted=\(accepted)")
            guard let self else { return }
            guard accepted else {
                self.chromiumTerminationPending = false
                return
            }
            var saveFailed = false
            self.windowManager.requestTermination(beforeCommit: { [weak self] in
                guard let self else { throw CocoaError(.userCancelled) }
                do { try self.windowManager.persistForRestart() }
                catch { saveFailed = true; throw error }
            }) { [weak self] pagesClosed in
                Self.trace("termination: pages closed=\(pagesClosed)")
                guard let self else { return }
                guard pagesClosed else {
                    ChromiumDownloadCoordinator.shared.resumeAfterCancelledTermination()
                    self.chromiumTerminationPending = false
                    if saveFailed {
                        let alert = NSAlert()
                        alert.messageText = L10n.string("Unable to Quit")
                        alert.informativeText = L10n.string("Nous could not save your tabs and windows. They remain open.")
                        alert.runModal()
                    }
                    return
                }
                ChromiumDownloadCoordinator.shared.shutdown()
                self.automation.stop()
                NBChromiumRuntime.completeApplicationTermination()
            }
        }
    }

    static func trace(_ message: String) {
        if ProcessInfo.processInfo.environment["NOUS_TRACE"] != nil { FileHandle.standardError.write(Data("Nous: \(message)\n".utf8)) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // NBApplication first waits for all beforeunload approvals and successful
        // session persistence, then enters AppKit termination. Sparkle uses this
        // same path; it never bypasses native page or download confirmation.
        automation.stop()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        chromiumWillShutDown()
    }

    /// Chromium's main loop ended (Chromium, not AppKit, ends the process).
    func chromiumWillShutDown() {
        automation.stop()
        ChromiumDownloadCoordinator.shared.shutdown()
    }

    private var settingsWindow: SettingsWindowController?

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(panes: BrowserSettingsPanes.make(
                preferences: windowManager.preferences, appearance: windowManager.appearance,
                passwordImporter: windowManager.passwordImporter, automation: automation))
        }
        settingsWindow?.showWindow(sender)
        settingsWindow?.window?.makeKeyAndOrderFront(sender)
        NSApp.activate()
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
