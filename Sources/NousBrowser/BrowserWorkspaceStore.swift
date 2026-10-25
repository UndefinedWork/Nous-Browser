import Foundation

/// Window identities select separate session files; website data remains in
/// WebKit's shared persistent store and is never copied into this manifest.
struct BrowserWindowSession: Codable, Equatable, Identifiable {
    let id: UUID
    let usesLegacySession: Bool

    init(id: UUID = UUID(), usesLegacySession: Bool = false) {
        self.id = id
        self.usesLegacySession = usesLegacySession
    }
}

@MainActor
final class BrowserWorkspaceStore {
    private struct Manifest: Codable {
        var version = 1
        var windows: [BrowserWindowSession]
        var activeWindowID: UUID?
    }

    let legacySessionURL: URL
    let manifestURL: URL
    let restoredWindows: [BrowserWindowSession]
    let restoredActiveWindowID: UUID?
    private var unreadableManifest: Data?

    init(sessionURL: URL? = nil) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nous Browser", isDirectory: true)
        legacySessionURL = sessionURL ?? directory.appendingPathComponent("session.json")
        manifestURL = legacySessionURL.deletingPathExtension().appendingPathExtension("windows.json")
        if let data = try? Data(contentsOf: manifestURL) {
            if let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.version == 1 {
                // Do not let a duplicated ID or legacy reference open two
                // windows that would both write to the same session file.
                var seenIDs = Set<UUID>()
                var hasLegacy = false
                let windows = manifest.windows.filter { window in
                    guard seenIDs.insert(window.id).inserted else { return false }
                    if window.usesLegacySession {
                        guard !hasLegacy else { return false }
                        hasLegacy = true
                    }
                    return true
                }
                restoredWindows = windows
                restoredActiveWindowID = windows.contains(where: { $0.id == manifest.activeWindowID })
                    ? manifest.activeWindowID : windows.last?.id
                return
            }
            // Preserve an unreadable or future manifest before writing a new
            // one; its individual session files are left untouched as well.
            unreadableManifest = data
        }
        let legacy = BrowserWindowSession(usesLegacySession: true)
        restoredWindows = [legacy]
        restoredActiveWindowID = legacy.id
    }

    func sessionURL(for window: BrowserWindowSession) -> URL {
        if window.usesLegacySession { return legacySessionURL }
        return legacySessionURL.deletingLastPathComponent()
            .appendingPathComponent(legacySessionURL.deletingPathExtension().lastPathComponent + "-windows", isDirectory: true)
            .appendingPathComponent(window.id.uuidString + ".json")
    }

    func makeWindowSession() -> BrowserWindowSession { BrowserWindowSession() }

    func save(windows: [BrowserWindowSession], activeWindowID: UUID?) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let unreadableManifest {
            let backup = manifestURL.deletingPathExtension()
                .appendingPathExtension("preserved-" + UUID().uuidString + ".json")
            try unreadableManifest.write(to: backup, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            self.unreadableManifest = nil
        }
        let active = windows.contains(where: { $0.id == activeWindowID }) ? activeWindowID : windows.last?.id
        let data = try JSONEncoder().encode(Manifest(windows: windows, activeWindowID: active))
        try data.write(to: manifestURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }
}
