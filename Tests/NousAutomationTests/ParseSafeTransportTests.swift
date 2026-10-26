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
