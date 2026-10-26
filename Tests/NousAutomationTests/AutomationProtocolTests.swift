import Foundation
import Testing
@testable import NousAutomation

@Suite("Automation protocol and schema")
struct AutomationProtocolTests {
    @Test func jsonRoundTripsWithoutTypeCoercion() throws {
        let value: JSONValue = .object(["bool": .bool(true), "number": .number(2),
            "array": .array([.null, .string("中文\ntext")])])
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data("true".utf8)).doubleValue == nil)
    }

    @Test func malformedArgumentsFailBeforeConnectingToBrowser() {
        #expect(throws: AutomationError.self) { try AutomationToolCatalog.validate(.init(tool: "browser_fill", arguments: ["tab_id": .string("tab")])) }
        #expect(throws: AutomationError.self) { try AutomationToolCatalog.validate(.init(tool: "browser_list_windows", arguments: ["script": .string("x")])) }
        #expect(throws: AutomationError.self) { try AutomationToolCatalog.validate(.init(tool: "browser_scroll", arguments: ["tab_id": .string("tab"), "x": .number(.infinity), "y": .number(0)])) }
        #expect(throws: AutomationError.self) { try AutomationToolCatalog.validate(.init(tool: "browser_reload", arguments: ["tab_id": .string("tab"), "bypass_cache": .string("true")])) }
        #expect(throws: AutomationError.self) { try AutomationToolCatalog.validate(.init(tool: "browser_evaluate", arguments: [:])) }
    }

    @Test func catalogIsUniqueAndUsesExplicitPageTargets() throws {
        #expect(AutomationToolCatalog.tools.count == 16)
        #expect(Set(AutomationToolCatalog.tools.map(\.name)).count == AutomationToolCatalog.tools.count)
        for tool in AutomationToolCatalog.tools {
            #expect(tool.inputSchema.objectValue?["additionalProperties"] == .bool(false))
            let encoded = try JSONEncoder().encode(tool.inputSchema)
            #expect(try JSONSerialization.jsonObject(with: encoded) is [String: Any])
        }
        for name in ["browser_snapshot", "browser_screenshot", "browser_navigate", "browser_click", "browser_fill", "browser_press_key", "browser_scroll"] {
            #expect(AutomationToolCatalog.tools.first { $0.name == name }?.required.contains("tab_id") == true)
        }
    }

    @Test func socketPathRejectsRelativeNulAndOverlongInputs() {
        #expect(throws: AutomationError.self) { try AutomationSocketClient.makeAddress("relative.sock") }
        #expect(throws: AutomationError.self) { try AutomationSocketClient.makeAddress("/tmp/a\0b") }
        #expect(throws: AutomationError.self) { try AutomationSocketClient.makeAddress("/" + String(repeating: "x", count: 104)) }
    }
}
