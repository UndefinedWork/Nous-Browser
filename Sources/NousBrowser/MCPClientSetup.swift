import Foundation

/// Adds Nous Browser to the MCP settings of agent apps on this Mac, so setup is
/// one click instead of editing JSON or TOML. Only the "nous-browser" entry is
/// written; everything else in those files is left as it was.
enum MCPClientSetup: String, CaseIterable, Identifiable {
    case codex, claudeDesktop

    static let serverName = "nous-browser"
    var id: Self { self }

    var title: String {
        switch self {
        case .codex: "Codex / ChatGPT"
        case .claudeDesktop: "Claude"
        }
    }

    var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return switch self {
        case .codex: home.appendingPathComponent(".codex/config.toml")
        case .claudeDesktop: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        }
    }

    /// The app has been used on this Mac (its settings folder exists).
    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: configURL.deletingLastPathComponent().path)
    }

    func isConfigured(helper: String) -> Bool {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
        switch self {
        case .codex:
            return Self.tomlCommand(in: text) == helper
        case .claudeDesktop:
            guard let data = text.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = root["mcpServers"] as? [String: Any],
                  let entry = servers[Self.serverName] as? [String: Any] else { return false }
            return entry["command"] as? String == helper
        }
    }

    func install(helper: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let updated: String
        switch self {
        case .codex:
            updated = Self.tomlInstalling(helper: helper, into: existing)
        case .claudeDesktop:
            var root: [String: Any] = [:]
            if !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let data = existing.data(using: .utf8),
                      let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: configURL.path])
                }
                root = parsed
            }
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            var entry = servers[Self.serverName] as? [String: Any] ?? [:]
            entry["command"] = helper
            entry.removeValue(forKey: "args")
            servers[Self.serverName] = entry
            root["mcpServers"] = servers
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            updated = String(decoding: data, as: UTF8.self) + "\n"
        }
        guard updated != existing else { return }
        try Data(updated.utf8).write(to: configURL, options: .atomic)
    }

    // MARK: TOML

    private static let header = "[mcp_servers.\(serverName)]"

    static func tomlCommand(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else { return nil }
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard trimmed.hasPrefix("command"), let equals = trimmed.firstIndex(of: "=") else { continue }
            return unquote(trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func tomlInstalling(helper: String, into text: String) -> String {
        let command = "command = \(quote(helper))"
        var lines = text.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) {
            var index = start + 1
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("command") {
                    lines[index] = command
                    return lines.joined(separator: "\n")
                }
                index += 1
            }
            lines.insert(command, at: start + 1)
            return lines.joined(separator: "\n")
        }
        var result = text
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        if !result.isEmpty { result += "\n" }
        return result + header + "\n" + command + "\n"
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}
