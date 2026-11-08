import Foundation

/// Distribution identity selects user data; the compiled renderer does not.
/// Preview and production must never share a session, runtime lock or MCP socket.
nonisolated struct BrowserRuntimePaths {
    enum Distribution: Equatable, Sendable {
        case production, preview

        static func resolve(bundleIdentifier: String?, channel: String?) -> Self? {
            switch (bundleIdentifier, channel) {
            case ("com.cellier.nous-browser", "github"): .production
            case ("com.cellier.nous-browser.chromium-preview", "chromium-preview"): .preview
            default: nil
            }
        }
    }

    let distribution: Distribution
    let directory: URL
    let automationSocketPath: String

    init(distribution: Distribution, applicationSupport: URL, home: URL) {
        self.distribution = distribution
        directory = applicationSupport.appendingPathComponent(
            distribution == .production ? "Nous Browser" : "Nous Browser Chromium Preview",
            isDirectory: true)
        automationSocketPath = home.appendingPathComponent(distribution == .production
            ? ".local/share/NousBrowser/automation/bridge.sock"
            : ".local/share/NousBrowser/previews/chromium/bridge.sock").path
    }

    var chromiumProfileDirectory: URL { directory.appendingPathComponent("Chromium", isDirectory: true) }
    var sessionURL: URL { directory.appendingPathComponent("session.json") }

    func sessionURL(qaOverride: String?) -> URL {
        guard distribution == .preview, let path = qaOverride, path.hasPrefix("/") else { return sessionURL }
        return URL(fileURLWithPath: path)
    }

    static var currentDistribution: Distribution? {
        Distribution.resolve(bundleIdentifier: Bundle.main.bundleIdentifier,
            channel: Bundle.main.object(forInfoDictionaryKey: "NousDistributionChannel") as? String)
    }

    static var current: Self {
        // The launcher rejects unknown identities before starting Chromium.
        // Non-app test hosts may construct controllers, but never select real data.
        .init(distribution: currentDistribution ?? .preview,
              applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
              home: FileManager.default.homeDirectoryForCurrentUser)
    }
}
