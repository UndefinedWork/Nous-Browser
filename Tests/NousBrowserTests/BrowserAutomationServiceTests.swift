import AppKit
import Foundation
import Testing
import NousAutomation
@testable import NousBrowser

@Suite("Private automation service", .serialized)
@MainActor
struct BrowserAutomationServiceTests {
    private func location() throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/NousBrowser/tests-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func ready(_ isReady: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if isReady() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AutomationError("Private listener did not become ready.")
    }

    @Test func privateSocketRoundTripAndImmediateRevocation() async throws {
        let directory = try location()
        let path = directory.appendingPathComponent("bridge.sock").path
        let server = AutomationSocketServer(path: path) { request in
            AutomationResponse(result: .object(["tool": .string(request.tool)]))
        }
        var running = false
        server.onStateChanged = { value, _ in running = value }
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        try server.start()
        try await ready { running }
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        let client = AutomationSocketClient(socketPath: path, timeout: 2)
        let result = try await client.call(AutomationRequest(tool: "browser_list_windows"))
        #expect(result.result?.objectValue?["tool"] == .string("browser_list_windows"))
        server.stop()
        await #expect(throws: (any Error).self) {
            _ = try await client.call(AutomationRequest(tool: "browser_list_windows"))
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func refusesToReplaceFilesOrAnActiveListener() async throws {
        let directory = try location()
        let file = directory.appendingPathComponent("bridge.sock")
        try Data("keep".utf8).write(to: file)
        let server = AutomationSocketServer(path: file.path) { _ in AutomationResponse(result: .bool(true)) }
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        #expect(throws: (any Error).self) { try server.start() }
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
        try FileManager.default.removeItem(at: file)
        var running = false
        server.onStateChanged = { value, _ in running = value }
        try server.start()
        try await ready { running }
        let other = AutomationSocketServer(path: file.path) { _ in AutomationResponse(result: .null) }
        defer { other.stop() }
        #expect(throws: (any Error).self) { try other.start() }
        let result = try await AutomationSocketClient(socketPath: file.path).call(AutomationRequest(tool: "browser_list_windows"))
        #expect(result.result == .bool(true))
    }

    @Test func stopCancelsAnInFlightOperation() async throws {
        let directory = try location()
        let path = directory.appendingPathComponent("bridge.sock").path
        var began = false
        var cancelled = false
        let server = AutomationSocketServer(path: path) { _ in
            began = true
            do { try await Task.sleep(for: .seconds(10)) }
            catch { cancelled = true }
            return AutomationResponse(result: .null)
        }
        var running = false
        server.onStateChanged = { value, _ in running = value }
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        try server.start()
        try await ready { running }
        let call = Task { try await AutomationSocketClient(socketPath: path, timeout: 3).call(AutomationRequest(tool: "browser_list_windows")) }
        try await ready { began }
        server.stop()
        _ = try? await call.value
        try await ready { cancelled }
    }

    @Test func serviceStartsOffAndPersistsOnlyExplicitEnablement() async throws {
        _ = NSApplication.shared
        let directory = try location()
        let domain = "NousAutomationTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        let manager = BrowserWindowManager(workspace: BrowserWorkspaceStore(sessionURL: directory.appendingPathComponent("session.json")),
                                           appearance: BrowserAppearanceSettings(defaults: defaults),
                                           preferences: BrowserPreferences(defaults: defaults),
                                           showsWindows: false, startsHibernationMonitors: false)
        let service = BrowserAutomationService(windows: manager, defaults: defaults,
                                                socketPath: directory.appendingPathComponent("bridge.sock").path)
        defer {
            service.stop()
            manager.prepareForTermination()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        service.startIfEnabled()
        #expect(!service.isEnabled && !service.isRunning)
        service.setEnabled(true)
        try await ready { service.isRunning }
        #expect(defaults.bool(forKey: BrowserAutomationService.enabledKey))
        service.setEnabled(false)
        #expect(!service.isRunning && !defaults.bool(forKey: BrowserAutomationService.enabledKey))
    }

    @Test func clientCancellationCancelsPendingPageWork() async throws {
        let directory = try location()
        let path = directory.appendingPathComponent("bridge.sock").path
        var began = false
        var cancelled = false
        let server = AutomationSocketServer(path: path) { _ in
            began = true
            do { try await Task.sleep(for: .seconds(10)) }
            catch { cancelled = true }
            return AutomationResponse(result: .null)
        }
        var running = false
        server.onStateChanged = { value, _ in running = value }
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        try server.start()
        try await ready { running }
        let call = Task { try await AutomationSocketClient(socketPath: path, timeout: 3).call(AutomationRequest(tool: "browser_list_windows")) }
        try await ready { began }
        call.cancel()
        _ = try? await call.value
        try await ready { cancelled }
    }
}
