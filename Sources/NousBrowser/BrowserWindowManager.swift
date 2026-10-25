import AppKit
import Observation
import SwiftUI

/// Owns browser windows independently of SwiftUI's Settings scene. Keeping the
/// active identity here also gives menu commands the same target as AppKit.
@MainActor
@Observable
final class BrowserWindowManager {
    let appearance: BrowserAppearanceSettings
    private(set) var windows: [BrowserWindowContext] = []
    private(set) var activeWindowID: UUID?

    @ObservationIgnored private let workspace: BrowserWorkspaceStore
    @ObservationIgnored private let showsWindows: Bool
    @ObservationIgnored private let startsHibernationMonitors: Bool
    @ObservationIgnored private var didRestoreWindows = false
    @ObservationIgnored private var isTerminating = false

    var activeContext: BrowserWindowContext? {
        windows.first { $0.session.id == activeWindowID } ?? windows.last
    }
    var activeController: BrowserController? { activeContext?.controller }
    var activeWindow: NSWindow? { activeContext?.window }

    init(workspace: BrowserWorkspaceStore, appearance: BrowserAppearanceSettings = BrowserAppearanceSettings(),
         showsWindows: Bool = true, startsHibernationMonitors: Bool = true) {
        self.workspace = workspace
        self.appearance = appearance
        self.showsWindows = showsWindows
        self.startsHibernationMonitors = startsHibernationMonitors
    }

    func restoreWindows() {
        guard !didRestoreWindows, !isTerminating else { return }
        didRestoreWindows = true
        // A URL-open event can arrive before didFinishLaunching. Never restore
        // a second copy of the workspace after routing that first event.
        guard windows.isEmpty else { return }
        for session in workspace.restoredWindows {
            _ = makeWindow(session: session, restoring: true)
        }
        guard !windows.isEmpty else {
            newWindow()
            return
        }
        activeWindowID = windows.contains { $0.session.id == workspace.restoredActiveWindowID }
            ? workspace.restoredActiveWindowID : windows.last?.session.id
        if showsWindows {
            for context in windows where context.session.id != activeWindowID {
                context.window.orderFront(nil)
            }
        }
        if let activeContext { activate(activeContext) }
        saveWorkspace()
    }

    @discardableResult
    func newWindow() -> BrowserWindowContext? {
        guard !isTerminating else { return nil }
        let context = makeWindow(session: workspace.makeWindowSession(), restoring: false)
        context.controller.showAddress(animated: false)
        activate(context)
        saveWorkspace()
        return context
    }

    /// With no open windows, Cmd-T is equivalent to Cmd-N, rather than making
    /// an empty window and adding a second empty tab to it.
    func newTab() {
        guard !isTerminating else { return }
        if let controller = activeController { controller.newTab() }
        else { newWindow() }
    }

    func showWindow() {
        guard !isTerminating else { return }
        if !didRestoreWindows { restoreWindows() }
        if let activeContext { activate(activeContext) }
        else { newWindow() }
    }

    func open(_ urls: [URL]) {
        let urls = urls.filter(BrowserModel.canOpenExternalURL)
        guard !urls.isEmpty, !isTerminating else { return }
        if !didRestoreWindows {
            if workspace.restoredWindows.contains(where: {
                FileManager.default.fileExists(atPath: workspace.sessionURL(for: $0).path)
            }) {
                restoreWindows()
            } else {
                // On a first-ever launch from a link there is no prior page to
                // restore. Open the requested page without a default Apple tab.
                didRestoreWindows = true
            }
        }
        if let context = activeContext {
            // When every window was closed, the first incoming URL occupies
            // the one fresh blank tab instead of leaving an extra blank page.
            if context.controller.model.tabs.count == 1,
               let first = context.controller.model.selectedTab, !first.hasWebContent, first.url == nil {
                first.load(urls[0])
                for url in urls.dropFirst() { context.controller.model.newTab(url: url) }
                context.controller.model.persistSession()
            } else {
                for url in urls { context.controller.model.newTab(url: url) }
            }
            context.controller.dismissAddress()
            activate(context)
        } else {
            let context = makeWindow(session: workspace.makeWindowSession(), restoring: false)
            context.controller.model.selectedTab?.load(urls[0])
            for url in urls.dropFirst() { context.controller.model.newTab(url: url) }
            context.controller.model.persistSession()
            activate(context)
        }
        saveWorkspace()
    }

    func closeActiveWindow() {
        guard let id = activeContext?.session.id else { return }
        closeWindow(id)
    }

    func closeWindow(_ id: UUID) {
        guard let context = windows.first(where: { $0.session.id == id }) else { return }
        context.window.performClose(nil)
    }

    func activate(_ context: BrowserWindowContext) {
        guard windows.contains(where: { $0 === context }), !isTerminating else { return }
        setActiveWindow(context.session.id)
        if showsWindows {
            if context.window.isMiniaturized { context.window.deminiaturize(nil) }
            context.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        saveWorkspace()
    }

    func prepareForTermination() {
        guard !isTerminating else { return }
        // Persist before shutdown and before AppKit can close individual
        // windows. Those close callbacks must not erase the restore manifest.
        saveWorkspace()
        isTerminating = true
        windows.forEach { $0.shutdown() }
    }

    private func makeWindow(session: BrowserWindowSession, restoring: Bool) -> BrowserWindowContext {
        let model = BrowserModel(sessionURL: workspace.sessionURL(for: session), restoreSession: restoring,
                                 startWithBlankTab: !restoring || !session.usesLegacySession)
        let controller = BrowserController(model: model, appearance: appearance)
        let context = BrowserWindowContext(session: session, controller: controller,
                                           cascadeFrom: activeWindow,
                                           startsHibernationMonitor: startsHibernationMonitors)
        context.onBecomeKey = { [weak self, weak context] in
            guard let self, let context, !self.isTerminating else { return }
            self.setActiveWindow(context.session.id)
            self.saveWorkspace()
        }
        context.onClose = { [weak self, weak context] in
            guard let self, let context else { return }
            self.didClose(context)
        }
        controller.onNewWindow = { [weak self] in _ = self?.newWindow() }
        controller.onCloseWindow = { [weak self] in self?.closeWindow(session.id) }
        windows.append(context)
        model.persistSession()
        return context
    }

    private func didClose(_ context: BrowserWindowContext) {
        guard let index = windows.firstIndex(where: { $0 === context }) else { return }
        context.shutdown()
        windows.remove(at: index)
        if activeWindowID == context.session.id { activeWindowID = windows.last?.session.id }
        if !isTerminating { saveWorkspace() }
    }

    private func setActiveWindow(_ id: UUID) {
        guard activeWindowID != id else { return }
        // A device-auth prompt may temporarily take key status. Cancel only
        // when another browser window becomes active, so an authorization can
        // never finish by filling a page left in a different window.
        activeController?.passwords.dismiss()
        activeWindowID = id
    }

    private func saveWorkspace() {
        guard !isTerminating else { return }
        do { try workspace.save(windows: windows.map(\.session), activeWindowID: activeWindowID) }
        catch { NSLog("Nous Browser: Could not save window workspace: %@", error.localizedDescription) }
    }
}

@MainActor
final class BrowserWindowContext: NSObject, NSWindowDelegate {
    let session: BrowserWindowSession
    let controller: BrowserController
    let window: NSWindow
    var onBecomeKey: (() -> Void)?
    var onClose: (() -> Void)?
    private let hibernationMonitor: TabHibernationMonitor
    private var isShutDown = false

    init(session: BrowserWindowSession, controller: BrowserController, cascadeFrom: NSWindow?,
         startsHibernationMonitor: Bool) {
        self.session = session
        self.controller = controller
        hibernationMonitor = TabHibernationMonitor(model: controller.model)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Nous Browser"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 540, height: 400)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.delegate = self
        window.contentView = NSHostingView(rootView: BrowserShell(controller: controller))
        let frameName = session.usesLegacySession ? "NousBrowserMainWindow" : "NousBrowserWindow-" + session.id.uuidString
        window.setFrameAutosaveName(frameName)
        if !window.setFrameUsingName(frameName) {
            if let cascadeFrom {
                window.cascadeTopLeft(from: NSPoint(x: cascadeFrom.frame.minX + 24, y: cascadeFrom.frame.maxY - 24))
            } else { window.center() }
        }
        hideWindowButtons()
        if startsHibernationMonitor { hibernationMonitor.start() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        hideWindowButtons()
        onBecomeKey?()
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        hibernationMonitor.stop()
        controller.shutdown()
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort) }
        window.contentView = nil
        window.delegate = nil
        onBecomeKey = nil
        onClose = nil
    }

    private func hideWindowButtons() {
        [.closeButton, .miniaturizeButton, .zoomButton].forEach {
            window.standardWindowButton($0)?.isHidden = true
        }
    }
}
