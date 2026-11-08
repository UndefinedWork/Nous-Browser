import AppKit
import Foundation
import NousAutomation

/// Sends each tool call to the running browser. When the browser is not
/// running, the helper opens it in the background and waits for it, so an
/// agent's first call works without the user switching apps.
struct BrowserBridge: Sendable {
    let client: AutomationSocketClient
    /// Only the installed browser's own endpoint; tests pass an explicit socket.
    let launchesBrowser: Bool

    static let bundleIdentifier = "com.cellier.nous-browser"

    func call(_ request: AutomationRequest) async throws -> AutomationResponse {
        do {
            return try await client.call(request)
        } catch let error as AutomationError where error == AutomationSocketClient.unavailable {
            guard launchesBrowser else { throw error }
            if !(await Self.isRunning()) {
                guard await Self.launch() else {
                    throw AutomationError("Nous Browser could not be opened. Open it yourself, then try again.")
                }
                guard await waitForEndpoint(seconds: 25) else {
                    throw AutomationError("Nous Browser opened, but AI agent access is off. In Nous Browser, open Settings > AI Agents (MCP) and turn on \"Allow AI agents to use Nous Browser\", then try again.")
                }
            } else if !(await waitForEndpoint(seconds: 4)) {
                throw AutomationError("Nous Browser is open, but AI agent access is off. In Nous Browser, open Settings > AI Agents (MCP) and turn on \"Allow AI agents to use Nous Browser\", then try again.")
            }
            return try await client.call(request)
        }
    }

    private func waitForEndpoint(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if AutomationSocketClient.isListening(client.socketPath) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return AutomationSocketClient.isListening(client.socketPath)
    }

    @MainActor
    private static func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// The app this helper ships in, so the matching copy opens.
    private static var enclosingApp: URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    @MainActor
    private static func launch() async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let url = enclosingApp ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        guard let url else { return false }
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                continuation.resume(returning: app != nil && error == nil)
            }
        }
    }
}
