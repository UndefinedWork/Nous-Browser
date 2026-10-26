import Foundation
import MCP
import Testing
@testable import NousMCP
import NousAutomation

@Suite("Official MCP SDK interoperability")
struct NousMCPServerTests {
    @Test func initializeListAndCallUseStandardProtocol() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "nous-browser", version: "test", capabilities: .init(tools: .init(listChanged: false)))
        let requests = RequestRecorder()
        await NousMCPServer.registerHandlers(on: server) { request in
            await requests.record(request)
            return .init(result: .object(["windows": .array([])]))
        }
        try await server.start(transport: serverTransport)
        let client = Client(name: "Independent SDK client", version: "1.0")
        do {
            let initialized = try await client.connect(transport: clientTransport)
            #expect(initialized.serverInfo.name == "nous-browser")
            #expect(initialized.capabilities.tools != nil)
            let (tools, cursor) = try await client.listTools()
            #expect(tools.count == 16)
            #expect(cursor == nil)
            #expect(tools.first { $0.name == "browser_snapshot" }?.annotations.readOnlyHint == true)
            #expect(tools.first { $0.name == "browser_close_tab" }?.annotations.destructiveHint == true)
            let request = CallTool.request(.init(name: "browser_list_windows", arguments: [:]))
            let context: RequestContext<CallTool.Result> = try await client.send(request)
            let result = try await context.value
            #expect(result.isError == false)
            #expect(result.structuredContent?.objectValue?["windows"]?.arrayValue?.isEmpty == true)
            #expect(await requests.count == 1)
            await client.disconnect()
            await server.stop()
        } catch {
            await client.disconnect()
            await server.stop()
            throw error
        }
    }

    @Test func invalidArgumentsNeverReachBrowser() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "nous-browser", version: "test", capabilities: .init(tools: .init()))
        let requests = RequestRecorder()
        await NousMCPServer.registerHandlers(on: server) { request in
            await requests.record(request)
            return .init(result: .object([:]))
        }
        try await server.start(transport: serverTransport)
        let client = Client(name: "schema-test", version: "1.0")
        try await client.connect(transport: clientTransport)
        do {
            _ = try await client.callTool(name: "browser_click", arguments: ["tab_id": "tab", "ref": "e1"])
            Issue.record("Missing snapshot_id was accepted")
        } catch let error as MCPError {
            if case .invalidParams = error {} else { Issue.record("Expected invalid params, got \(error)") }
        }
        do {
            _ = try await client.callTool(name: "browser_evaluate", arguments: ["script": "document.cookie"])
            Issue.record("Unknown tool was accepted")
        } catch let error as MCPError {
            if case .invalidParams = error {} else { Issue.record("Expected invalid params, got \(error)") }
        }
        #expect(await requests.count == 0)
        await client.disconnect()
        await server.stop()
    }

    @Test func browserFailuresAreToolErrorsAndImagesAreNativeMCPContent() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "nous-browser", version: "test", capabilities: .init(tools: .init()))
        await NousMCPServer.registerHandlers(on: server) { request in
            if request.tool == "browser_screenshot" {
                return .init(result: .object(["width": .number(1)]), imageBase64: "test-image-base64")
            }
            return .init(error: "Automation is disabled.")
        }
        try await server.start(transport: serverTransport)
        let client = Client(name: "tool-result-test", version: "1.0")
        try await client.connect(transport: clientTransport)
        let (errorContent, isError) = try await client.callTool(name: "browser_list_windows", arguments: [:])
        #expect(isError == true)
        #expect(errorContent.count == 1)
        let (imageContent, imageError) = try await client.callTool(name: "browser_screenshot", arguments: ["tab_id": "tab"])
        #expect(imageError == false)
        #expect(imageContent.count == 2)
        if case .image(let data, let mimeType, _, _) = imageContent.last {
            #expect(data == "test-image-base64")
            #expect(mimeType == "image/png")
        } else { Issue.record("Screenshot did not use MCP image content") }
        await client.disconnect()
        await server.stop()
    }
}

private actor RequestRecorder {
    var count = 0
    func record(_ request: AutomationRequest) { count += 1 }
}
