import AppKit
import Foundation
import NousAutomation
import Testing
@testable import NousBrowser

@Suite("Browser MCP automation", .serialized)
@MainActor
struct BrowserAutomationTests {
    @Test func listingUsesStableIDsWithoutChangingTheActiveWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let first = try #require(fixture.manager.newWindow())
        let second = try #require(fixture.manager.newWindow())
        let result = await fixture.call("browser_list_windows")
        let list = try #require(result.result?.objectValue?["windows"]?.arrayValue)
        #expect(list.count == 2)
        #expect(Set(list.compactMap { $0.objectValue?["window_id"]?.stringValue }) == Set([first.session.id.uuidString, second.session.id.uuidString]))
        #expect(fixture.manager.activeWindowID == second.session.id)
        let tabs = await fixture.call("browser_list_tabs", ["window_id": .string(first.session.id.uuidString)])
        #expect(tabs.result?.objectValue?["tabs"]?.arrayValue?.count == 1)
        #expect(fixture.manager.activeWindowID == second.session.id)
    }

    @Test func newTabTargetsItsExplicitWindowAndInsertionPoint() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let first = try #require(fixture.manager.newWindow())
        let source = try #require(first.controller.model.selectedTabID)
        first.controller.model.newTab()
        let oldSecond = try #require(first.controller.model.selectedTabID)
        let other = try #require(fixture.manager.newWindow())
        let result = await fixture.call("browser_new_tab", ["window_id": .string(first.session.id.uuidString), "after_tab_id": .string(source.uuidString)])
        #expect(result.error == nil)
        let newID = try #require(result.result?.objectValue?["tab_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        #expect(first.controller.model.tabs.map(\.id) == [source, newID, oldSecond])
        #expect(other.controller.model.tabs.count == 1)
        #expect(!first.controller.isAddressPresented)
    }

    @Test func selectingAndClosingExplicitTabsDoesNotUseTheKeyWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let first = try #require(fixture.manager.newWindow())
        let firstTab = try #require(first.controller.model.selectedTabID)
        let second = try #require(fixture.manager.newWindow())
        let selected = await fixture.call("browser_select_tab", ["tab_id": .string(firstTab.uuidString)])
        #expect(selected.error == nil)
        #expect(fixture.manager.activeWindowID == first.session.id)
        fixture.manager.activate(second)
        let closed = await fixture.call("browser_close_tab", ["tab_id": .string(firstTab.uuidString)])
        #expect(closed.error == nil)
        #expect(fixture.manager.windows.map { $0.session.id } == [second.session.id])
        #expect(second.controller.model.tabs.count == 1)
    }

    @Test func missingAndStaleIDsNeverFallBackToTheActiveTab() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let context = try #require(fixture.manager.newWindow())
        let tabID = try #require(context.controller.model.selectedTabID)
        for request in [
            AutomationRequest(tool: "browser_close_tab"),
            AutomationRequest(tool: "browser_close_tab", arguments: ["tab_id": .string(UUID().uuidString)]),
            AutomationRequest(tool: "browser_new_tab", arguments: ["window_id": .string("not-a-window")]),
            AutomationRequest(tool: "browser_new_tab", arguments: ["window_id": .string(context.session.id.uuidString), "after_tab_id": .string(UUID().uuidString)])
        ] {
            #expect(await fixture.executor.execute(request).error != nil)
        }
        #expect(fixture.manager.windows.count == 1)
        #expect(context.controller.model.tabs.map(\.id) == [tabID])
    }

    @Test func executorEnforcesThePublicToolCatalogAtThePrivateBoundary() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        for request in [
            AutomationRequest(tool: "evaluate_javascript", arguments: ["script": .string("document.cookie")]),
            AutomationRequest(tool: "browser_list_windows", arguments: ["unexpected": .bool(true)]),
            AutomationRequest(tool: "browser_list_tabs", arguments: ["window_id": .number(1)])
        ] { #expect(await fixture.executor.execute(request).error != nil) }
        #expect(fixture.manager.windows.isEmpty)
    }

    @Test(arguments: ["file:///etc/passwd", "data:text/html,secret", "javascript:alert(1)", "mailto:user@example.test", "https://user:secret@example.test/", "example.test", "about:blank"])
    func unsupportedURLsCannotChangeATabOrCreateAWindow(candidate: String) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let context = try #require(fixture.manager.newWindow())
        let tab = try #require(context.controller.model.selectedTab)
        #expect(await fixture.call("browser_navigate", ["tab_id": .string(tab.id.uuidString), "url": .string(candidate)]).error != nil)
        #expect(await fixture.call("browser_new_window", ["url": .string(candidate)]).error != nil)
        #expect(tab.url == nil)
        #expect(fixture.manager.windows.count == 1)
    }

    @Test func emptyPagesCannotBeReadAndURLsNeverReturnEmbeddedCredentials() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let context = try #require(fixture.manager.newWindow())
        let tab = try #require(context.controller.model.selectedTab)
        #expect(await fixture.call("browser_snapshot", ["tab_id": .string(tab.id.uuidString)]).error != nil)
        tab.url = URL(string: "https://username:secret@example.test/path")
        let result = await fixture.call("browser_list_tabs")
        let data = try JSONEncoder().encode(result)
        #expect(!String(decoding: data, as: UTF8.self).contains("secret"))
        #expect(!String(decoding: data, as: UTF8.self).contains("username"))
    }

}

@MainActor
private final class Fixture {
    let directory: URL
    let defaults: UserDefaults
    let defaultsDomain: String
    let manager: BrowserWindowManager
    let executor: BrowserAutomationExecutor

    init() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Nous-MCP-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsDomain = "NousMCPTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: defaultsDomain)!
        manager = BrowserWindowManager(workspace: BrowserWorkspaceStore(sessionURL: directory.appendingPathComponent("session.json")),
            appearance: BrowserAppearanceSettings(defaults: defaults), preferences: BrowserPreferences(defaults: defaults),
            showsWindows: false)
        executor = BrowserAutomationExecutor(windows: manager)
    }

    func call(_ tool: String, _ arguments: [String: JSONValue] = [:]) async -> AutomationResponse {
        await executor.execute(.init(tool: tool, arguments: arguments))
    }

    func close() {
        manager.prepareForTermination()
        manager.windows.forEach { $0.window.close() }
        defaults.removePersistentDomain(forName: defaultsDomain)
        try? FileManager.default.removeItem(at: directory)
    }
}
