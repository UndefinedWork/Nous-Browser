import Foundation
import MCP

/// SDK 0.12.1 synthesizes a random request ID for undecodable JSON. JSON-RPC
/// requires `id: null` when the request ID cannot be determined. Correct only
/// that malformed-JSON boundary; all valid messages, lifecycle, negotiation and
/// cancellation remain owned by the official SDK.
actor ParseSafeTransport: Transport {
    nonisolated let logger = StdioTransport().logger
    private let base: any Transport
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var task: Task<Void, Never>?

    init(_ base: any Transport) {
        self.base = base
        (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
    }

    func connect() async throws {
        guard task == nil else { return }
        try await base.connect()
        task = Task { await readLoop() }
    }

    func disconnect() async {
        task?.cancel()
        task = nil
        await base.disconnect()
        continuation.finish()
    }

    func send(_ data: Data) async throws { try await base.send(data) }
    func receive() -> AsyncThrowingStream<Data, Error> { stream }

    private func readLoop() async {
        do {
            for try await data in await base.receive() {
                try Task.checkCancellation()
                if (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) == nil {
                    try await base.send(Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error: invalid JSON"}}"#.utf8))
                    continue
                }
                continuation.yield(data)
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}
