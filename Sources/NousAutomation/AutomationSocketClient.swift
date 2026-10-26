import Darwin
import Foundation

/// One bounded request per connection. The endpoint must be a same-user Unix
/// socket in a private directory. The GUI's directory/socket permissions limit
/// inbound access to the current user; this client also checks the server UID.
public struct AutomationSocketClient: Sendable {
    public let socketPath: String
    public let timeout: TimeInterval
    public init(socketPath: String = AutomationEndpoint.defaultSocketPath, timeout: TimeInterval = 35) {
        self.socketPath = socketPath
        self.timeout = timeout.isFinite ? min(max(timeout, 0.05), 35) : 35
    }

    public func call(_ request: AutomationRequest) async throws -> AutomationResponse {
        try AutomationToolCatalog.validate(request)
        let task = Task.detached { try exchange(request) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
    }

    private func exchange(_ request: AutomationRequest) throws -> AutomationResponse {
        try Task.checkCancellation()
        try Self.validateEndpoint(socketPath)
        var address = try Self.makeAddress(socketPath)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AutomationError("Unable to create the local browser connection.") }
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw AutomationError("Unable to configure the local browser connection.") }
        var suppressSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppressSignal, socklen_t(MemoryLayout<Int32>.size))
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw Self.unavailable }
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw Self.unavailable }
        }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
            throw AutomationError("The local browser endpoint belongs to another user.")
        }
        var encoded = try JSONEncoder().encode(request)
        guard encoded.count <= AutomationEndpoint.maxRequestBytes else { throw AutomationError("The automation request is too large.") }
        encoded.append(0x0A)
        try encoded.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                let sent = Darwin.send(fd, base.advanced(by: offset), raw.count - offset, 0)
                if sent < 0, errno == EINTR || errno == EAGAIN { continue }
                guard sent > 0 else { throw Self.unavailable }
                offset += sent
            }
        }
        var received = Data()
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { throw AutomationError("Nous Browser closed the connection before returning a result.") }
            let chunk = bytes[..<count]
            if let newline = chunk.firstIndex(of: 0x0A) {
                received.append(contentsOf: chunk[..<newline])
                guard received.count <= AutomationEndpoint.maxResponseBytes else { throw AutomationError("The browser response is too large.") }
                guard chunk[(newline + 1)...].allSatisfy({ $0 == 0x0A || $0 == 0x0D }) else {
                    throw AutomationError("Invalid browser response framing.")
                }
                return try JSONDecoder().decode(AutomationResponse.self, from: received)
            }
            received.append(contentsOf: chunk)
            guard received.count <= AutomationEndpoint.maxResponseBytes else { throw AutomationError("The browser response is too large.") }
        }
    }

    private func wait(_ fd: Int32, events: Int16, deadline: ContinuousClock.Instant) throws {
        while true {
            try Task.checkCancellation()
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw AutomationError("Nous Browser did not respond before the connection deadline.") }
            // Poll in short intervals so cancellation does not wait for the full timeout.
            let milliseconds = min(200, max(1, Int(remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000)))
            var event = pollfd(fd: fd, events: events, revents: 0)
            let ready = Darwin.poll(&event, 1, Int32(milliseconds))
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { throw Self.unavailable }
            if ready == 0 { continue }
            if event.revents & events != 0 { return }
            if event.revents & Int16(POLLERR | POLLNVAL | POLLHUP) != 0 { throw Self.unavailable }
        }
    }

    private static var unavailable: AutomationError {
        AutomationError("Nous Browser is not connected. Open Nous Browser, then enable Settings > AI Agents (MCP).")
    }

    public static func validateEndpoint(_ path: String) throws {
        _ = try makeAddress(path)
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var directoryInfo = stat()
        guard lstat(directory, &directoryInfo) == 0 else { throw unavailable }
        guard directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == geteuid(), directoryInfo.st_mode & 0o077 == 0 else {
            throw AutomationError("The automation directory must be owned by this user with permissions 0700.")
        }
        var socketInfo = stat()
        guard lstat(path, &socketInfo) == 0 else { throw unavailable }
        guard socketInfo.st_mode & S_IFMT == S_IFSOCK,
              socketInfo.st_uid == geteuid(), socketInfo.st_mode & 0o077 == 0 else {
            throw AutomationError("The automation endpoint must be a same-user private socket with permissions 0600.")
        }
    }

    public static func makeAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard path.hasPrefix("/"), !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw AutomationError("The automation socket path must be absolute and shorter than 104 UTF-8 bytes.")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return address
    }
}
