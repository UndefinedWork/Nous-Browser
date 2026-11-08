import AppKit
import Foundation
import Testing
@testable import NousBrowser

@Suite("Chromium detached pages present in their owning window", .serialized)
@MainActor
struct ChromiumDialogPresentationTests {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        return window
    }

    private func model(_ directory: URL, _ name: String) -> BrowserModel {
        BrowserModel(sessionURL: directory.appendingPathComponent(name + ".json"),
                     restoreSession: false, loadSelectedTab: false, startWithBlankTab: true)
    }

    @Test func detachedPageKeepsOwningWindowWithoutMountingOrReloading() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = model(directory, "detached")
        let window = window()
        defer { model.shutdown(); window.close(); try? FileManager.default.removeItem(at: directory) }
        model.chromiumPresentationWindow = window
        let page = try #require(model.selectedTab?.webView)
        window.contentView?.addSubview(page)
        #expect(page.window === window)
        page.removeFromSuperview()
        #expect(page.window == nil)
        #expect(page.dialogPresentationWindow === window)
        #expect(page.url == nil && !page.isLoading)
    }

    @Test func transferChangesPresenterBeforeDestinationViewMounts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = model(directory, "source"), destination = model(directory, "destination")
        let oldWindow = window(), newWindow = window()
        defer {
            source.shutdown(); destination.shutdown(); oldWindow.close(); newWindow.close()
            try? FileManager.default.removeItem(at: directory)
        }
        source.chromiumPresentationWindow = oldWindow
        destination.chromiumPresentationWindow = newWindow
        let tab = try #require(source.selectedTab)
        oldWindow.contentView?.addSubview(tab.webView)
        #expect(source.takeTabForTransfer(tab.id) === tab)
        #expect(tab.owner == nil && tab.webView.dialogPresentationWindow == nil)
        #expect(destination.adoptTransferredTab(tab, at: 0))
        #expect(tab.webView.window == nil)
        #expect(tab.webView.dialogPresentationWindow === newWindow)
        #expect(tab.webView.dialogPresentationWindow !== oldWindow)
    }

    @Test func clearingOwnerDoesNotFallBackToFormerPhysicalWindow() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = model(directory, "owner")
        let window = window()
        let tab = BrowserTab(owner: model)
        defer { tab.shutdown(); model.shutdown(); window.close(); try? FileManager.default.removeItem(at: directory) }
        model.chromiumPresentationWindow = window
        tab.owner = model
        window.contentView?.addSubview(tab.webView)
        #expect(tab.webView.window === window)
        tab.owner = nil
        // takeTabForTransfer changes ownership before removing the native view.
        #expect(tab.webView.window === window)
        #expect(tab.webView.dialogPresentationWindow == nil)
    }

    @Test func newTabsInheritPresenterAndShutdownClearsEveryTab() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = model(directory, "new-tabs")
        let window = window()
        defer { model.shutdown(); window.close(); try? FileManager.default.removeItem(at: directory) }
        model.chromiumPresentationWindow = window
        model.newTab()
        #expect(model.tabs.count == 2)
        #expect(model.tabs.allSatisfy { $0.webView.dialogPresentationWindow === window })
        model.shutdown()
        #expect(model.chromiumPresentationWindow == nil)
        #expect(model.tabs.allSatisfy { $0.webView.dialogPresentationWindow == nil })
    }

    @Test func unmanagedFixtureDefaultsToAttachedWindowButExplicitNilDisablesIt() {
        let window = window()
        let page = ChromiumPageView(frame: .zero)
        defer { page.shutdown(); window.close() }
        window.contentView?.addSubview(page)
        #expect(page.dialogPresentationWindow === window)
        page.dialogPresentationWindow = nil
        #expect(page.window === window && page.dialogPresentationWindow == nil)
    }
}
