import Foundation
import MCP
import Testing
@testable import NousMCP

@Suite("MCP malformed JSON boundary")
struct ParseSafeTransportTests {
    @Test func malformedJSONHasNullIDAndValidBytesPassThrough() async throws {
        let (client, base) = await InMemoryTransport.createConnectedPair()
        let transport = ParseSafeTransport(base)
        try await client.connect()
        try await transport.connect()
        var replies = await client.receive().makeAsyncIterator()
        try await client.send(Data("{invalid".utf8))
        let response = try #require(try await replies.next())
        let json = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        #expect(json["id"] is NSNull)
        #expect((json["error"] as? [String: Any])?["code"] as? Int == -32700)
        let valid = Data(#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#.utf8)
        var requests = await transport.receive().makeAsyncIterator()
        try await client.send(valid)
        #expect(try await requests.next() == valid)
        await transport.disconnect()
        #expect(try await requests.next() == nil)
        await client.disconnect()
    }
}

@Suite("Client compatibility")
struct InitializeCompatibilityTests {
    @Test func experimentalClientCapabilitiesAreDroppedBeforeTheSDKDecodesThem() throws {
        let raw = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/sandbox-state":{"version":"1"}},"roots":{}},"clientInfo":{"name":"codex","version":"1"}}}"#
        let data = Data(raw.utf8)
        let cleaned = ParseSafeTransport.compatible(data, object: try JSONSerialization.jsonObject(with: data))
        let object = try #require(try JSONSerialization.jsonObject(with: cleaned) as? [String: Any])
        let capabilities = try #require((object["params"] as? [String: Any])?["capabilities"] as? [String: Any])
        #expect(capabilities["experimental"] == nil)
        #expect(capabilities["roots"] != nil)
        let other = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)
        #expect(ParseSafeTransport.compatible(other, object: try JSONSerialization.jsonObject(with: other)) == other)
    }
}
