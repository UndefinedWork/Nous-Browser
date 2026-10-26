import Foundation
import MCP
import NousAutomation

enum NousMCPServer {
    static func registerHandlers(on server: Server,
        execute: @escaping @Sendable (AutomationRequest) async throws -> AutomationResponse) async {
        await server.withMethodHandler(ListTools.self) { params in
            // This small, static catalog fits one page. A cursor cannot name a
            // subsequent page and must not silently return duplicate tools.
            guard params.cursor == nil else { throw MCPError.invalidParams("Unknown tools cursor.") }
            return .init(tools: try AutomationToolCatalog.tools.map { definition in
                Tool(name: definition.name, description: definition.description,
                     inputSchema: try Value(definition.inputSchema),
                     annotations: .init(readOnlyHint: definition.readOnly,
                         destructiveHint: definition.destructive,
                         idempotentHint: definition.readOnly,
                         openWorldHint: true))
            })
        }
        await server.withMethodHandler(CallTool.self) { params in
            guard AutomationToolCatalog.tools.contains(where: { $0.name == params.name }) else {
                throw MCPError.invalidParams("Unknown tool: \(params.name.prefix(128)).")
            }
            let arguments = try JSONDecoder().decode([String: JSONValue].self,
                from: JSONEncoder().encode(params.arguments ?? [:]))
            let request = AutomationRequest(tool: params.name, arguments: arguments)
            do { try AutomationToolCatalog.validate(request) }
            catch { throw MCPError.invalidParams(error.localizedDescription) }
            do {
                try Task.checkCancellation()
                let response = try await execute(request)
                try Task.checkCancellation()
                if let error = response.error {
                    return .init(content: [.text(text: error, annotations: nil, _meta: nil)], isError: true)
                }
                let result = response.result ?? .object(["ok": .bool(true)])
                let data = try JSONEncoder().encode(result)
                var content: [Tool.Content] = [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)]
                if let image = response.imageBase64 {
                    content.append(.image(data: image, mimeType: "image/png", annotations: nil, _meta: nil))
                }
                return .init(content: content, structuredContent: Optional.some(try Value(result)), isError: false)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
            }
        }
    }
}
