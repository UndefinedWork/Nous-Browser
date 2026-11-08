import AppKit
import Foundation
import NousAutomation
import Testing
@testable import NousBrowser

@Suite("MCP spaces, groups and layout", .serialized)
@MainActor
struct BrowserLayoutAutomationTests {
    private static let plan: JSONValue = .array([
        .object(["name": .string("Work"), "icon": .string("briefcase"),
                 "pinned": .array([.object(["url": .string("https://mail.example.com/")])]),
                 "tabs": .array([
                    .object(["group": .string("Design"), "icon": .string("paintpalette"),
                             "tabs": .array([.object(["url": .string("https://figma.example.com")]),
                                             .object(["url": .string("https://dribbble.example.com")])])]),
                    .object(["url": .string("https://github.example.com"), "title": .string("GitHub")]),
                 ])]),
        .object(["name": .string("Reading"), "tabs": .array([.object(["url": .string("https://news.example.com")])])]),
    ])

    @Test func applyLayoutBuildsSpacesGroupsAndTabsAndIsSafeToRepeat() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let window = try #require(fixture.manager.newWindow())
        let model = window.controller.model
        let tabsBefore = model.tabs.count

        let first = await fixture.call("browser_apply_layout", ["spaces": Self.plan])
        #expect(first.error == nil)
        let result = try #require(first.result?.objectValue)
        #expect(result["created_tabs"]?.doubleValue == 5)
        #expect(result["created_groups"]?.doubleValue == 1)

        let work = try #require(model.spaces.first { $0.name == "Work" })
        #expect(work.icon == "briefcase")
        #expect(model.spaces.contains { $0.name == "Reading" })
        #expect(model.activeSpaceID == work.id)
        let layout = model.layout(for: work.id)
        #expect(layout.pinnedTabIDs.count == 1)
        let design = try #require(layout.regular.compactMap(\.group).first)
        #expect(design.name == "Design" && design.icon == "paintpalette" && design.tabIDs.count == 2)
        #expect(layout.regular.count == 2)
        // The window shows the first planned space.
        #expect(model.selectedTab.map { layout.contains(tab: $0.id) } ?? true)

        // The same plan again: nothing new, nothing moved.
        let second = await fixture.call("browser_apply_layout", ["spaces": Self.plan])
        #expect(second.error == nil)
        #expect(second.result?.objectValue?["created_tabs"]?.doubleValue == 0)
        #expect(second.result?.objectValue?["unchanged_tabs"]?.doubleValue == 5)
        #expect(model.tabs.count == tabsBefore + 5)
        #expect(model.spaces.filter { $0.name == "Work" }.count == 1)
    }

    @Test func layoutReadsBackAsATree() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let window = try #require(fixture.manager.newWindow())
        _ = await fixture.call("browser_apply_layout", ["spaces": Self.plan, "window_id": .string(window.session.id.uuidString)])
        let response = await fixture.call("browser_get_layout")
        let windows = try #require(response.result?.objectValue?["windows"]?.arrayValue)
        let spaces = try #require(windows.first?.objectValue?["spaces"]?.arrayValue)
        let work = try #require(spaces.first { $0.objectValue?["name"]?.stringValue == "Work" }?.objectValue)
        let tabs = try #require(work["tabs"]?.arrayValue)
        let group = try #require(tabs.first?.objectValue)
        #expect(group["type"]?.stringValue == "group")
        #expect(group["tabs"]?.arrayValue?.count == 2)
        #expect(work["pinned"]?.arrayValue?.count == 1)
    }

    @Test func groupAndTabToolsOrganizeExistingTabs() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let window = try #require(fixture.manager.newWindow())
        let model = window.controller.model
        model.newTab(url: URL(string: "https://a.example.com"))
        let a = try #require(model.selectedTabID)
        model.newTab(url: URL(string: "https://b.example.com"))
        let b = try #require(model.selectedTabID)

        let created = await fixture.call("browser_group", ["action": .string("create"), "name": .string("Pair"),
            "icon": .string("star"), "tab_ids": .array([.string(a.uuidString), .string(b.uuidString)])])
        #expect(created.error == nil)
        let groupID = try #require(created.result?.objectValue?["group_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        #expect(model.layout(for: model.activeSpaceID).group(groupID)?.tabIDs == [a, b])

        #expect(await fixture.call("browser_group", ["action": .string("pin"), "group_id": .string(groupID.uuidString)]).error == nil)
        #expect(model.layout(for: model.activeSpaceID).section(ofGroup: groupID) == .pinned)
        #expect(model.tab(a)?.isPinned == true)

        #expect(await fixture.call("browser_group", ["action": .string("unpin"), "group_id": .string(groupID.uuidString)]).error == nil)
        let moved = await fixture.call("browser_tab", ["action": .string("move"), "tab_id": .string(b.uuidString),
                                                       "section": .string("tabs"), "index": .number(0)])
        #expect(moved.error == nil)
        #expect(model.layout(for: model.activeSpaceID).group(groupID)?.tabIDs == [a])
        #expect(model.layout(for: model.activeSpaceID).regular.first == .tab(b))

        let space = await fixture.call("browser_space", ["action": .string("create"), "name": .string("Later"), "icon": .string("moon")])
        let spaceID = try #require(space.result?.objectValue?["space_id"]?.stringValue)
        #expect(await fixture.call("browser_tab", ["action": .string("move_to_space"), "tab_id": .string(b.uuidString),
                                                   "space_id": .string(spaceID)]).error == nil)
        #expect(model.tab(b)?.spaceID?.uuidString == spaceID)

        #expect(await fixture.call("browser_group", ["action": .string("ungroup"), "group_id": .string(groupID.uuidString)]).error == nil)
        #expect(model.layout(for: model.activeSpaceID).groups.isEmpty)
    }

    @Test func invalidPlansAreRejectedWithoutChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let window = try #require(fixture.manager.newWindow())
        let spaces = window.controller.model.spaces.count
        let badURL = await fixture.call("browser_apply_layout", ["spaces": .array([
            .object(["name": .string("X"), "tabs": .array([.object(["url": .string("file:///etc/passwd")])])])])])
        #expect(badURL.error?.contains("http") == true)
        let badIcon = await fixture.call("browser_space", ["action": .string("create"), "icon": .string("not-a-symbol")])
        #expect(badIcon.error != nil)
        let extra = await fixture.call("browser_apply_layout", ["spaces": .array([
            .object(["name": .string("X"), "colour": .string("red")])])])
        #expect(extra.error?.contains("unexpected") == true)
        #expect(window.controller.model.spaces.count == spaces)
        let last = await fixture.call("browser_delete_space", ["space_id": .string(window.controller.model.activeSpaceID.uuidString)])
        if spaces == 1 { #expect(last.error != nil) }
    }
}

@MainActor
private struct Fixture {
    let directory: URL
    let defaults: UserDefaults
    let defaultsDomain: String
    let manager: BrowserWindowManager
    let executor: BrowserAutomationExecutor

    init() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Nous-MCP-layout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsDomain = "NousMCPLayoutTests-" + UUID().uuidString
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
