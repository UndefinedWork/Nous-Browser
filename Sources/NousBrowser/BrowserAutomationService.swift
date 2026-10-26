import AppKit
import Darwin
import Foundation
import Network
import Observation
import NousAutomation

/// The GUI owns the live pages. MCP subprocesses only forward requests through
/// a private local socket while the user has enabled this service.
@MainActor
@Observable
final class BrowserAutomationService {
    private(set) var isEnabled = false
    private(set) var isRunning = false
    private(set) var statusMessage: String?
    private(set) var lastActivity: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let socketPath: String
    @ObservationIgnored private let executor: BrowserAutomationExecutor
    @ObservationIgnored private var server: AutomationSocketServer?
    @ObservationIgnored private var operation: Task<AutomationResponse, Never>?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var generation = UUID()
    static let enabledKey = "NousBrowserMCPEnabled"

    init(windows: BrowserWindowManager, defaults: UserDefaults = .standard, socketPath: String? = nil) {
        self.defaults = defaults
        self.socketPath = socketPath ?? AutomationEndpoint.defaultSocketPath
        executor = BrowserAutomationExecutor(windows: windows)
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    var connectionConfig: String {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/NousBrowserMCP").path
        var entry: [String: Any] = ["command": helper]
        if socketPath != AutomationEndpoint.defaultSocketPath { entry["args"] = ["--socket", socketPath] }
        let value = ["mcpServers": ["nous-browser": entry]]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func startIfEnabled() { if isEnabled { start() } }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        isEnabled = enabled
        if enabled { start() } else { stop() }
    }

    func stop() {
        generation = UUID()
        executor.invalidateSnapshots()
        operation?.cancel()
        operation = nil
        operationID = nil
        server?.stop()
        server = nil
        isRunning = false
        statusMessage = nil
    }

    private func start() {
        guard server == nil else { return }
        statusMessage = nil
        let token = generation
        let server = AutomationSocketServer(path: socketPath) { [weak self] request in
            guard let self, self.isEnabled, self.generation == token else {
                return AutomationResponse(error: "MCP access is disabled. Enable AI Agents (MCP) in Nous Browser Settings.")
            }
            guard self.operation == nil else {
                return AutomationResponse(error: "Nous Browser is processing another agent request. Retry after it completes.")
            }
            let id = UUID()
            self.operationID = id
            let task = Task { @MainActor in await self.executor.execute(request) }
            self.operation = task
            let result = await withTaskCancellationHandler {
                await task.value
            } onCancel: { task.cancel() }
            if self.operationID == id {
                self.operation = nil
                self.operationID = nil
            }
            guard self.generation == token, self.isEnabled, !Task.isCancelled else {
                return AutomationResponse(error: "MCP access was stopped.")
            }
            self.lastActivity = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            return result
        }
        server.onStateChanged = { [weak self] running, error in
            guard let self, self.generation == token else { return }
            self.isRunning = running
            self.statusMessage = error
            if error != nil { self.server = nil }
        }
        self.server = server
        do { try server.start() }
        catch {
            server.stop()
            self.server = nil
            isRunning = false
            statusMessage = error.localizedDescription
        }
    }
}

/// One bounded request per connection. The directory is accessible only to the
/// logged-in user; neither web origins nor remote machines get a listening port.
@MainActor
final class AutomationSocketServer {
    typealias Handler = @MainActor @Sendable (AutomationRequest) async -> AutomationResponse
    var onStateChanged: ((Bool, String?) -> Void)?
    private let path: String
    private let handler: Handler
    private var listener: NWListener?
    private var listenerGeneration = UUID()
    private var connections: [UUID: Connection] = [:]
    private var socketIdentity: (device: dev_t, inode: ino_t)?
    private let queue = DispatchQueue(label: "com.cellier.nous-browser.automation")

    private final class Connection {
        let network: NWConnection
        var bytes = Data()
        var timeout: Task<Void, Never>?
        var operation: Task<Void, Never>?
        var responding = false
        init(_ network: NWConnection) { self.network = network }
    }

    init(path: String, handler: @escaping Handler) { self.path = path; self.handler = handler }

    func start() throws {
        guard listener == nil else { return }
        try prepareSocketPath()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        let listener = try NWListener(using: parameters)
        let token = UUID()
        listenerGeneration = token
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.listener != nil, self.listenerGeneration == token else { return }
                switch state {
                case .ready:
                    var info = stat()
                    guard lstat(self.path, &info) == 0,
                          info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFSOCK,
                          chmod(self.path, 0o600) == 0 else {
                        self.stop()
                        self.onStateChanged?(false, "Could not protect the local automation socket.")
                        return
                    }
                    self.socketIdentity = (info.st_dev, info.st_ino)
                    self.onStateChanged?(true, nil)
                case .failed(let error):
                    self.stop()
                    self.onStateChanged?(false, error.localizedDescription)
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self, self.listenerGeneration == token else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listenerGeneration = UUID()
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.timeout?.cancel()
            connection.operation?.cancel()
            connection.network.cancel()
        }
        connections.removeAll()
        if let socketIdentity {
            var current = stat()
            if lstat(path, &current) == 0, current.st_dev == socketIdentity.device,
               current.st_ino == socketIdentity.inode, (current.st_mode & S_IFMT) == S_IFSOCK {
                unlink(path)
            }
        }
        socketIdentity = nil
    }

    private func accept(_ network: NWConnection) {
        guard listener != nil, connections.count < 8 else { network.cancel(); return }
        let id = UUID()
        let connection = Connection(network)
        connections[id] = connection
        network.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.finish(id) } }
            if case .cancelled = state { Task { @MainActor in self?.finish(id) } }
        }
        network.start(queue: queue)
        armTimeout(id, seconds: 5)
        receive(id)
    }

    private func receive(_ id: UUID) {
        guard let connection = connections[id], !connection.responding else { return }
        connection.network.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, let connection = self.connections[id], !connection.responding else { return }
                if let data { connection.bytes.append(data) }
                guard connection.bytes.count <= 1_048_576 else {
                    self.respond(AutomationResponse(error: "Request exceeds the 1 MiB limit."), to: id)
                    return
                }
                if let end = connection.bytes.firstIndex(of: 10) {
                    guard connection.bytes[(end + 1)...].allSatisfy({ [9, 10, 13, 32].contains($0) }),
                          let request = try? JSONDecoder().decode(AutomationRequest.self, from: connection.bytes[..<end]) else {
                        self.respond(AutomationResponse(error: "Invalid automation request; send one JSON object followed by a newline."), to: id)
                        return
                    }
                    connection.bytes.removeAll(keepingCapacity: false)
                    self.armTimeout(id, seconds: 25)
                    connection.operation = Task { @MainActor [weak self] in
                        guard let self, !Task.isCancelled else { return }
                        let response = await self.handler(request)
                        guard !Task.isCancelled else { return }
                        self.respond(response, to: id)
                    }
                    self.watchForDisconnect(id)
                } else if complete || error != nil { self.finish(id) }
                else { self.receive(id) }
            }
        }
    }

    private func watchForDisconnect(_ id: UUID) {
        guard let connection = connections[id] else { return }
        // A helper cancellation closes this socket. Continue reading while the
        // page operation is pending so a FIN cancels it before a delayed action.
        connection.network.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
            Task { @MainActor in self?.finish(id) }
        }
    }

    private func armTimeout(_ id: UUID, seconds: Double) {
        guard let connection = connections[id] else { return }
        connection.timeout?.cancel()
        connection.timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.connections[id]?.operation?.cancel()
            self.respond(AutomationResponse(error: "The browser request timed out. Inspect the page before retrying an action."), to: id)
        }
    }

    private func respond(_ response: AutomationResponse, to id: UUID) {
        guard let connection = connections[id], !connection.responding else { return }
        connection.responding = true
        connection.timeout?.cancel()
        var bytes = (try? JSONEncoder().encode(response)) ?? Data()
        if bytes.count > 16_777_216 {
            bytes = (try? JSONEncoder().encode(AutomationResponse(error: "Response exceeds the 16 MiB limit."))) ?? Data()
        }
        bytes.append(10)
        connection.network.send(content: bytes, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.finish(id) }
        })
        connection.timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.finish(id)
        }
    }

    private func finish(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.timeout?.cancel()
        connection.operation?.cancel()
        connection.network.cancel()
    }

    private func prepareSocketPath() throws {
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path), path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        // Reject symlink traversal instead of changing permissions through a link.
        var ancestor = URL(fileURLWithPath: "/", isDirectory: true)
        for component in directory.pathComponents.dropFirst() {
            ancestor.appendPathComponent(component, isDirectory: true)
            var info = stat()
            if lstat(ancestor.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw CocoaError(.fileWriteNoPermission) }
            } else if errno == ENOENT {
                guard mkdir(ancestor.path, 0o700) == 0 || errno == EEXIST else { throw CocoaError(.fileWriteNoPermission) }
            } else { throw CocoaError(.fileWriteNoPermission) }
        }
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0, directoryInfo.st_uid == geteuid(),
              chmod(directory.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_uid == geteuid(), (existing.st_mode & S_IFMT) == S_IFSOCK else {
                throw CocoaError(.fileWriteFileExists)
            }
            // Do not unlink another running Nous instance's endpoint.
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { Darwin.close(fd) }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.copyBytes(from: Array(path.utf8) + [0])
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == -1, errno == ECONNREFUSED || errno == ENOENT else { throw CocoaError(.fileWriteFileExists) }
            guard unlink(path) == 0 || errno == ENOENT else { throw CocoaError(.fileWriteNoPermission) }
        } else if errno != ENOENT { throw CocoaError(.fileReadNoPermission) }
    }
}
