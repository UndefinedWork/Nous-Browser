import Foundation
import Testing
@testable import NousBrowser

@Suite("One-click MCP client setup")
struct MCPClientSetupTests {
    private let helper = "/Applications/Nous Browser.app/Contents/MacOS/NousBrowserMCP"

    @Test func codexEntryIsAppendedOnceAndKeepsOtherSettings() {
        let original = "model = \"gpt\"\n\n[mcp_servers.other]\ncommand = \"/bin/other\"\n"
        let installed = MCPClientSetup.tomlInstalling(helper: helper, into: original)
        #expect(installed.hasPrefix(original))
        #expect(MCPClientSetup.tomlCommand(in: installed) == helper)
        #expect(MCPClientSetup.tomlInstalling(helper: helper, into: installed) == installed)
        #expect(installed.components(separatedBy: "[mcp_servers.nous-browser]").count == 2)
    }

    @Test func codexEntryWithAnOldPathIsUpdatedInPlace() {
        let original = "[mcp_servers.nous-browser]\ncommand = \"/old/NousBrowserMCP\"\nstartup_timeout_sec = 20\n\n[memories]\nuse = true\n"
        let installed = MCPClientSetup.tomlInstalling(helper: helper, into: original)
        #expect(MCPClientSetup.tomlCommand(in: installed) == helper)
        #expect(installed.contains("startup_timeout_sec = 20"))
        #expect(installed.contains("[memories]\nuse = true"))
    }

    @Test func emptyConfigGetsJustTheEntry() {
        let installed = MCPClientSetup.tomlInstalling(helper: helper, into: "")
        #expect(installed == "[mcp_servers.nous-browser]\ncommand = \"\(helper)\"\n")
    }
}
