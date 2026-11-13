import AppKit
import Foundation
import NousAutomation
import NousCore

/// Explicitly enabled acceptance harness for the separate preview bundle. It
/// operates only on the loopback synthetic fixture, never restored user pages.
@MainActor
enum ChromiumSmokeCheck {
    private static var didRun = false

    static func run(windowManager: BrowserWindowManager) {
        let environment = ProcessInfo.processInfo.environment
        guard !didRun,
              Bundle.main.bundleIdentifier?.contains("chromium-preview") == true,
              let report = environment["NOUS_CHROMIUM_SMOKE_REPORT"], !report.isEmpty,
              let base = URL(string: environment["NOUS_CHROMIUM_SMOKE_BASE_URL"] ?? "http://127.0.0.1:18866"),
              base.scheme == "http", base.host == "127.0.0.1" else { return }
        didRun = true
        Task { @MainActor in
            let runner = Runner(windows: windowManager, base: base, reportURL: URL(fileURLWithPath: report))
            await runner.run()
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @MainActor
    private final class Runner {
        let windows: BrowserWindowManager
        let base: URL
        let reportURL: URL
        var results: [[String: Any]] = []
        var pending = "starting"
        let started = Date()

        init(windows: BrowserWindowManager, base: URL, reportURL: URL) {
            self.windows = windows; self.base = base; self.reportURL = reportURL
        }

        func save(finished: Bool = false) {
            let report: [String: Any] = [
                "engine": NBChromiumRuntime.engineVersion(),
                "nativeTabLifecycleAvailable": NBChromiumRuntime.hasNativeTabLifecycle(),
                "nativeClosePreflightAvailable": NBChromiumRuntime.hasNativeClosePreflight(),
                "startedAt": ISO8601DateFormatter().string(from: started),
                "finished": finished, "pending": pending, "results": results,
                "limits": ["DOM capability probes do not prove native Finder drag/drop or Chinese IME.",
                           "Reload/cross-window storage checks do not prove persistence after app restart unless previousRunStorage is true.",
                           "Live tab retention checks do not prove Memory Saver discard/restore or edited-document eligibility.",
                           "This fixture is not a Zoom Slides sustained editing performance comparison."]
            ]
            do {
                try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
            } catch { NSLog("Nous Chromium smoke report unavailable: %@", error.localizedDescription) }
        }

        func check(_ name: String, _ action: () async throws -> [String: Any]) async {
            pending = name; save()
            do {
                let detail = try await action()
                results.append(["name": name, "status": "passed", "detail": detail])
            } catch {
                results.append(["name": name, "status": "failed", "error": String(describing: error)])
            }
            save()
        }

        func skip(_ name: String, _ reason: String) {
            results.append(["name": name, "status": "skipped", "reason": reason]); save()
        }

        func waitForPage(_ view: ChromiumPageView, path: String) async throws {
            for _ in 0..<160 {
                if view.url?.host == base.host, view.url?.path == path, !view.isLoading,
                   (try? await view.evaluateScript("document.readyState", world: "")) as? String == "complete" { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw Failure("Page did not finish loading: \(path)")
        }

        func dictionary(_ value: Any?) throws -> [String: Any] {
            guard let value = value as? [String: Any] else { throw Failure("Expected a structured engine response") }
            return value
        }

        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(message) }
        }

        // Run only in the opt-in preview harness against the local synthetic
        // fixture. The tester answers the native permission UI; no grants are
        // injected and no real clipboard, device, or location data is accessed.
        private func permissionLifecycle(in context: BrowserWindowContext, tab: BrowserTab) async throws -> [String: Any] {
            let path = "/permissions.html"
            tab.load(base.appendingPathComponent("permissions.html"))
            try await waitForPage(tab.webView, path: path)
            pending = "Click Request notification permission on the local fixture"; save()
            for _ in 0..<1200 {
                if context.window.attachedSheet != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let oldSheet = context.window.attachedSheet else { throw Failure("No permission sheet appeared") }
            let model = context.controller.model
            model.newTab()
            context.controller.dismissAddress()
            for _ in 0..<30 {
                if context.window.attachedSheet == nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(context.window.attachedSheet == nil, "Old permission sheet survived hiding its tab")
            model.selectTab(tab.id)
            for _ in 0..<30 {
                if context.window.attachedSheet != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let replacement = context.window.attachedSheet else { throw Failure("Pending permission was lost on tab return") }
            try require(replacement !== oldSheet, "Reused a stale permission sheet")
            pending = "Answer the replacement notification permission sheet"; save()
            for _ in 0..<1200 {
                if context.window.attachedSheet == nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(context.window.attachedSheet == nil, "Permission sheet was not answered")
            let query = "navigator.permissions.query({name:'notifications'}).then(p=>p.state)"
            let decision = try await tab.webView.evaluateScript(query, world: "") as? String
            try require(decision == "granted" || decision == "denied", "No persistent decision was made")
            tab.webView.reload()
            try await Task.sleep(for: .milliseconds(250))
            try await waitForPage(tab.webView, path: path)
            let afterReload = try await tab.webView.evaluateScript(query, world: "") as? String
            try require(afterReload == decision, "Permission changed on reload")
            model.newTab(url: base.appendingPathComponent("permissions.html"))
            guard let reopened = model.selectedTab else { throw Failure("Could not reopen fixture") }
            try await waitForPage(reopened.webView, path: path)
            let afterReopen = try await reopened.webView.evaluateScript(query, world: "") as? String
            try require(afterReopen == decision, "Permission changed in new tab")
            return ["oldSheetClosed": true, "replacementSheetCreated": true,
                    "decision": decision ?? "", "afterReload": afterReload ?? "", "afterReopen": afterReopen ?? "",
                    "limit": "Notification permission only; no real devices, clipboard reads, or geolocation requests."]
        }

        func run() async {
            save()
            await check("native-close-preflight-capability") {
                try self.require(NBChromiumRuntime.hasNativeClosePreflight(),
                                 "Native two-phase beforeunload is unavailable; no destructive fallback is permitted")
                return ["available": true,
                        "limit": "Capability discovery is not proof of real multi-window beforeunload Cancel/Leave behavior."]
            }
            guard let context = windows.newWindow(), let tab = context.controller.model.selectedTab else {
                results.append(["name": "create-window", "status": "failed"]); pending = "finished"; save(finished: true); return
            }
            context.controller.dismissAddress()
            context.window.title = "Nous Chromium — Synthetic acceptance"
            let view = tab.webView
            if ProcessInfo.processInfo.environment["NOUS_CHROMIUM_PERMISSION_LIFECYCLE"] == "1" {
                await check("permission-sheet-lifecycle-and-persistence") {
                    try await self.permissionLifecycle(in: context, tab: tab)
                }
                pending = "finished"; save(finished: true)
                return
            }
            view.nativeView.addScript("globalThis.__nousSmokeAtStart=document.readyState;globalThis.__nousSmokeIsolation='isolated';",
                                      world: "NousSmoke", binding: "__nousSmokeMessage")
            tab.load(base.appendingPathComponent(""))
            await check("initial-navigation") {
                try await self.waitForPage(view, path: "/")
                return ["url": view.url?.absoluteString ?? "", "title": view.title ?? ""]
            }
            await check("memory-saver-exception-preferences") {
                try self.memorySaverPreferenceRoundTrip()
            }
            if let phase = ProcessInfo.processInfo.environment["NOUS_CHROMIUM_MEMORY_PREFS_PHASE"] {
                await check("memory-saver-exception-restart-\(phase)") {
                    try self.memorySaverPreferenceRestart(phase: phase)
                }
            }
            await check("engine-and-codecs") {
                let info = try self.dictionary(await view.evaluateScript(#"""
                (()=>{const v=document.createElement('video'),a=document.createElement('audio');return {
                    ua:navigator.userAgent,dpr:devicePixelRatio,wasm:typeof WebAssembly==='object',
                    h264:v.canPlayType('video/mp4; codecs="avc1.42E01E"'),
                    aac:a.canPlayType('audio/mp4; codecs="mp4a.40.2"'),
                    webm:v.canPlayType('video/webm; codecs="vp9, opus"'),
                    dataTransfer:typeof DataTransfer==='function',file:typeof File==='function',
                    fileInput:document.getElementById('files').type
                }})()
                """#, world: ""))
                try self.require((info["ua"] as? String)?.contains("Chrome/") == true, "Page is not reporting Chromium")
                try self.require((info["dpr"] as? Double ?? 0) > 0, "Invalid device pixel ratio")
                return info
            }
            await check("isolated-document-start") {
                let isolated = try self.dictionary(await view.evaluateScript("({atStart:globalThis.__nousSmokeAtStart,value:globalThis.__nousSmokeIsolation})", world: "NousSmoke"))
                let main = try self.dictionary(await view.evaluateScript("({isolated:typeof globalThis.__nousSmokeIsolation,binding:typeof globalThis.__nousSmokeMessage,password:typeof globalThis.__nousPasswordCandidate})", world: ""))
                try self.require(isolated["value"] as? String == "isolated", "Isolated document-start script did not run")
                try self.require(isolated["atStart"] as? String == "loading", "Script ran after document start")
                try self.require(main.values.allSatisfy { $0 as? String == "undefined" }, "Native binding or isolated state exposed to webpage")
                return ["isolated": isolated, "pageWorld": main]
            }
            await check("iframe-binding-isolation") {
                var reply: [String: Any] = [:]
                for _ in 0..<30 {
                    if let value = try await view.evaluateScript("window.__fixture?.iframeReport", world: "") as? [String: Any] { reply = value; break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try self.require(reply["passwordBinding"] as? String == "undefined" && reply["smokeBinding"] as? String == "undefined", "A cross-origin page can access a native binding, or iframe did not load")
                return reply
            }
            await check("isolated-context-cache-and-cancellation") {
                try await self.scriptContextLifecycle()
            }
            await check("reload-storage") {
                let initial = try self.dictionary(await view.evaluateScript(#"""
                (()=>{const previous=localStorage.getItem('nous.chromium.smoke');localStorage.setItem('nous.chromium.smoke','fixture-only-v1');document.cookie='nous_chromium_smoke=fixture-only-v1; Path=/; Max-Age=86400; SameSite=Lax';return {previousRunStorage:previous==='fixture-only-v1'}})()
                """#, world: ""))
                view.reload()
                try await Task.sleep(for: .milliseconds(250))
                try await self.waitForPage(view, path: "/")
                let restored = try self.dictionary(await view.evaluateScript("({local:localStorage.getItem('nous.chromium.smoke'),cookie:document.cookie.includes('nous_chromium_smoke=fixture-only-v1')})", world: ""))
                try self.require(restored["local"] as? String == "fixture-only-v1" && restored["cookie"] as? Bool == true, "Storage not retained across reload")
                return ["before": initial, "after": restored]
            }
            await check("mcp-snapshot-and-safe-fill") {
                let executor = BrowserAutomationExecutor(windows: self.windows)
                // Tab actions resolve the owning window internally. window_id is
                // a response field here, not an accepted snapshot/fill argument.
                let target: [String: JSONValue] = ["tab_id": .string(tab.id.uuidString)]
                let snapshot = await executor.execute(.init(tool: "browser_snapshot", arguments: target))
                try self.require(snapshot.error == nil, snapshot.error ?? "snapshot failed")
                let data = try JSONEncoder().encode(snapshot.result)
                let text = String(decoding: data, as: UTF8.self)
                try self.require(text.contains("Message"), "MCP snapshot missed the visible input")
                guard let object = snapshot.result?.objectValue,
                      let snapshotID = object["snapshot_id"]?.stringValue,
                      let elements = object["elements"]?.arrayValue,
                      let message = elements.first(where: { $0.objectValue?["name"]?.stringValue == "Message" }),
                      let ref = message.objectValue?["ref"]?.stringValue else { throw Failure("MCP did not return an addressable Message input") }
                var fill = target
                fill["snapshot_id"] = .string(snapshotID); fill["ref"] = .string(ref); fill["text"] = .string("synthetic-mcp-value")
                let filled = await executor.execute(.init(tool: "browser_fill", arguments: fill))
                try self.require(filled.error == nil, filled.error ?? "MCP fill failed")
                let actual = try await view.evaluateScript("document.getElementById('message').value", world: "") as? String
                try self.require(actual == "synthetic-mcp-value", "MCP filled value was not visible in the DOM")
                let fileSnapshot = await executor.execute(.init(tool: "browser_snapshot", arguments: target))
                try self.require(fileSnapshot.error == nil, fileSnapshot.error ?? "File-field snapshot failed")
                guard let fileObject = fileSnapshot.result?.objectValue,
                      let fileSnapshotID = fileObject["snapshot_id"]?.stringValue,
                      let file = fileObject["elements"]?.arrayValue?.first(where: { $0.objectValue?["type"]?.stringValue == "file" }),
                      let fileRef = file.objectValue?["ref"]?.stringValue else {
                    throw Failure("MCP snapshot omitted the fixture file field")
                }
                fill["snapshot_id"] = .string(fileSnapshotID)
                fill["ref"] = .string(fileRef)
                let forbidden = await executor.execute(.init(tool: "browser_fill", arguments: fill))
                try self.require(forbidden.error?.contains("Password and file fields cannot be operated through MCP.") == true,
                                 "File-field test did not reach the restricted-field guard: \(forbidden.error ?? "operation accepted")")
                return ["snapshotBytes": data.count, "containsVisibleMessage": true, "safeFillVerified": true, "fileFillRejected": true]
            }
            await check("background-tab-scheduling") {
                try await self.backgroundScheduling(in: context, tab: tab)
            }
            await check("never-selected-background-link") {
                try await self.neverSelectedBackground(in: context, preserving: tab)
            }
            await check("background-tab-retention-over-deck-limit") {
                try await self.backgroundRetention(in: context, preserving: tab)
            }
            await check("selected-tabs-in-two-windows") {
                try await self.selectedWindowRetention(in: context, preserving: tab)
            }
            await check("find-request-lifecycle") {
                try await self.findLifecycle(in: context, preserving: tab)
            }
            await check("cross-window-live-tab") {
                _ = try await view.evaluateScript("globalThis.__nousLiveTransfer='preserve-live-page';document.getElementById('editor').value='unsaved fixture only';true", world: "")
                guard let destination = self.windows.moveTabToNewWindow(tab.id, from: context.session.id) else {
                    throw Failure("Tab transfer did not create a destination window")
                }
                try self.require(destination.controller.model.selectedTab?.webView === view, "Transfer recreated Chromium view")
                for _ in 0..<100 {
                    if view.window === destination.window,
                       let responder = destination.window.firstResponder as? NSView,
                       responder === view || responder.isDescendant(of: view) { break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                let responder = destination.window.firstResponder as? NSView
                try self.require(view.window === destination.window && (responder === view || responder?.isDescendant(of: view) == true),
                                 "Transferred page did not regain focus in its actual destination window")
                var state = try self.dictionary(await view.evaluateScript("({live:globalThis.__nousLiveTransfer,text:document.getElementById('editor').value,storage:localStorage.getItem('nous.chromium.smoke')})", world: ""))
                try self.require(state["live"] as? String == "preserve-live-page" && state["text"] as? String == "unsaved fixture only", "Live page state was lost on transfer")
                state["focusRestoredAfterMount"] = true
                return state
            }
            await check("script-popup-blocker") {
                let before = Set(self.windows.windows.flatMap { $0.controller.model.tabs.map(\.id) })
                _ = try await view.evaluateScript("window.open('/popup','nousSmokePopup');true", world: "")
                try await Task.sleep(for: .milliseconds(350))
                let after = Set(self.windows.windows.flatMap { $0.controller.model.tabs.map(\.id) })
                try self.require(before == after, "A script without a user gesture opened a popup")
                return ["nonGesturePopupBlocked": true]
            }
            skip("trusted-popup-opener", "Click the synthetic Open popup with opener button through native input, then verify window.__hasOpener and opener.__popupReply; evaluated scripts intentionally receive no user gesture.")
            #if DEBUG
            await passwordChecks()
            #else
            skip("password-safe-fill", "Production disables HTTP autofill. Run DEBUG preview for synthetic loopback form tests; HTTPS/device-authentication paths are unchanged.")
            #endif
            skip("native-file-drop-and-ime", "Requires native Finder drag and a real Chinese composition; DOM probes cannot prove these interactions.")
            pending = "finished"; save(finished: true)
        }

        /// Uses the actual CEF profile preference API, not a UserDefaults mock.
        /// Only our unique synthetic domain is changed; every pre-existing rule
        /// and all managed policy entries must survive the transaction.
        func memorySaverPreferenceRoundTrip() throws -> [String: Any] {
            let before = try NBChromiumRuntime.memorySaverSites()
            try require(before["canEdit"] as? Bool == true, "Synthetic preview profile unexpectedly has read-only exceptions")
            let domain = "nous-smoke-\(UUID().uuidString.lowercased()).invalid"
            var needsCleanup = false
            do {
                try NBChromiumRuntime.addMemorySaverSite(domain)
                needsCleanup = true
                try NBChromiumRuntime.addMemorySaverSite(domain)
                let added = try NBChromiumRuntime.memorySaverSites()
                let actual = added["sites"] as? [String] ?? []
                try require(actual.filter { $0 == domain }.count == 1, "Duplicate addition changed exception identity")
                try require(Set(actual) == Set(before["sites"] as? [String] ?? []).union([domain]), "Adding a site changed unrelated exceptions")
                try require((added["managedSites"] as? [String]) == (before["managedSites"] as? [String]), "Managed exceptions changed")
                var invalidRejected = false
                do { try NBChromiumRuntime.addMemorySaverSite("https://invalid.example/path") }
                catch { invalidRejected = true }
                try require(invalidRejected, "Native preference boundary accepted a URL instead of a canonical domain")
                try NBChromiumRuntime.removeMemorySaverSite(domain)
                needsCleanup = false
                try NBChromiumRuntime.removeMemorySaverSite(domain)
                let after = try NBChromiumRuntime.memorySaverSites()
                try require(NSDictionary(dictionary: before).isEqual(to: after), "Exception preferences were not restored")
                return ["addReadback": true, "duplicateIdempotent": true, "invalidRejected": invalidRejected,
                        "removeReadback": true, "originalRulesRetained": true,
                        "limit": "Preference round-trip does not prove engine discard eligibility or restart persistence."]
            } catch {
                if needsCleanup { try? NBChromiumRuntime.removeMemorySaverSite(domain) }
                throw error
            }
        }

        /// Opt-in two-launch check. Seed and verify must use the same built app
        /// and encrypted preview profile, with a normal quit between launches.
        /// The record contains only a synthetic domain and a process identifier.
        func memorySaverPreferenceRestart(phase: String) throws -> [String: Any] {
            guard let path = ProcessInfo.processInfo.environment["NOUS_CHROMIUM_MEMORY_PREFS_RECORD"],
                  path.hasPrefix("/"), ["seed", "verify"].contains(phase) else {
                throw Failure("Restart check requires seed/verify and an absolute synthetic record path")
            }
            let recordURL = URL(fileURLWithPath: path)
            if phase == "seed" {
                try require(!FileManager.default.fileExists(atPath: path), "Refusing to overwrite a previous restart-test record")
                let domain = "nous-restart-\(UUID().uuidString.lowercased()).invalid"
                try NBChromiumRuntime.addMemorySaverSite(domain)
                do {
                    let data = try JSONSerialization.data(withJSONObject: ["domain": domain, "pid": ProcessInfo.processInfo.processIdentifier])
                    try data.write(to: recordURL, options: .withoutOverwriting)
                } catch {
                    try? NBChromiumRuntime.removeMemorySaverSite(domain)
                    throw error
                }
                return ["seeded": true, "restartVerified": false]
            }
            let record = try dictionary(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)))
            guard let domain = record["domain"] as? String,
                  domain.hasPrefix("nous-restart-"), domain.hasSuffix(".invalid"),
                  ChromiumMemorySaverDomain.normalized(domain) == domain,
                  let oldPID = record["pid"] as? Int else { throw Failure("Invalid synthetic restart record") }
            try require(oldPID != Int(ProcessInfo.processInfo.processIdentifier), "Restart verification ran in the original process")
            let before = try NBChromiumRuntime.memorySaverSites()
            try require((before["sites"] as? [String] ?? []).contains(domain), "Exception was not restored after a normal process restart")
            try NBChromiumRuntime.removeMemorySaverSite(domain)
            let after = try NBChromiumRuntime.memorySaverSites()
            try require(!(after["sites"] as? [String] ?? []).contains(domain), "Restart-test exception cleanup failed")
            return ["restartVerified": true, "syntheticRuleRemoved": true,
                    "limit": "Persistence is verified; actual Memory Saver eligibility is a separate test."]
        }

        /// Exercise the real protocol bridge across repeated calls, navigation
        /// and destruction, without reading any restored user page.
        func scriptContextLifecycle() async throws -> [String: Any] {
            let view = ChromiumPageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Nous Chromium — Script lifecycle fixture"
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            defer { view.shutdown(); window.close() }
            let world = "NousContextLifecycle"
            view.load(URLRequest(url: base.appendingPathComponent("page2")))
            try await waitForPage(view, path: "/page2")
            _ = try await view.evaluateScript("globalThis.__nousContextCounter=900;true", world: "")
            for index in 1...20 {
                let count = try await view.evaluateScript("globalThis.__nousContextCounter=(globalThis.__nousContextCounter||0)+1", world: world) as? Int
                try require(count == index, "Isolated context state was lost or exposed to the page world")
            }
            try require(try await view.evaluateScript("globalThis.__nousContextCounter", world: "") as? Int == 900,
                        "Isolated evaluation changed page-world state")
            let navigating = ScriptReceipt()
            view.evaluate("globalThis.__nousPending=true;new Promise(()=>{})", world: world) { _, error in
                MainActor.assumeIsolated { navigating.errors.append(error != nil) }
            }
            for _ in 0..<30 {
                if try await view.evaluateScript("globalThis.__nousPending===true", world: world) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            view.load(URLRequest(url: base.appendingPathComponent("")))
            try await waitForPage(view, path: "/")
            for _ in 0..<80 {
                if !navigating.errors.isEmpty { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try require(navigating.errors == [true], "Navigation did not cancel the old script exactly once")
            let reset = try dictionary(await view.evaluateScript("({counter:typeof globalThis.__nousContextCounter,pending:typeof globalThis.__nousPending})", world: world))
            try require(reset.values.allSatisfy { $0 as? String == "undefined" }, "New document reused stale isolated state")
            let closing = ScriptReceipt()
            view.evaluate("globalThis.__nousClosing=true;new Promise(()=>{})", world: world) { _, error in
                MainActor.assumeIsolated { closing.errors.append(error != nil) }
            }
            for _ in 0..<30 {
                if try await view.evaluateScript("globalThis.__nousClosing===true", world: world) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            view.shutdown()
            for _ in 0..<80 {
                if !closing.errors.isEmpty { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try await Task.sleep(for: .milliseconds(200))
            try require(closing.errors == [true] && navigating.errors == [true], "Closing left a missing or duplicate script completion")
            return ["isolatedCalls": 20, "pageWorldUntouched": true, "newDocumentStateReset": true,
                    "navigationCancellation": navigating.errors, "closeCancellation": closing.errors]
        }

        @MainActor
        private final class ScriptReceipt { var errors: [Bool] = [] }

        @MainActor
        private final class FindReceipt {
            let label: String
            let started = Date()
            var values: [Bool] = []
            var elapsedMilliseconds: [Int] = []

            init(_ label: String) { self.label = label }
            func receive(_ found: Bool) {
                values.append(found)
                elapsedMilliseconds.append(Int(Date().timeIntervalSince(started) * 1_000))
            }
            var detail: [String: Any] {
                ["request": label, "results": values, "completionMilliseconds": elapsedMilliseconds]
            }
        }

        /// Exercise native CEF Find replies rather than mirroring the queue in a
        /// mock. The temporary page contains only synthetic, visible test text.
        func findLifecycle(in context: BrowserWindowContext, preserving original: BrowserTab) async throws -> [String: Any] {
            let model = context.controller.model
            model.newTab(url: base.appendingPathComponent("page2"))
            guard let target = model.selectedTab, target.id != original.id else { throw Failure("Cannot create synthetic Find tab") }
            context.controller.dismissAddress()
            let view = target.webView
            defer {
                view.stopFinding()
                model.selectTab(original.id)
                model.closeTab(target.id)
            }
            try await waitForPage(view, path: "/page2")
            _ = try await view.evaluateScript("document.body.replaceChildren(Object.assign(document.createElement('p'),{textContent:'NousFindAlpha42 NousFindBeta42 NousFindAlpha42 NousFindBeta42 NousFindAlpha42 NousFindBeta42'}));true", world: "")
            // Let the actual renderer lay out the searchable text first.
            try await Task.sleep(for: .milliseconds(150))
            var receipts: [FindReceipt] = []
            func submit(_ label: String, _ text: String, next: Bool = false, backwards: Bool = false) -> FindReceipt {
                let receipt = FindReceipt(label)
                receipts.append(receipt)
                view.findText(text, backwards: backwards, next: next) { found in
                    MainActor.assumeIsolated { receipt.receive(found) }
                }
                return receipt
            }
            func wait(_ pending: [FindReceipt]) async throws {
                // A fixture search should respond far before the bridge's
                // defensive ten-second timeout. Do not hang on a missing reply.
                let deadline = Date().addingTimeInterval(5)
                while pending.contains(where: { $0.values.isEmpty }), Date() < deadline {
                    try await Task.sleep(for: .milliseconds(25))
                }
                try require(pending.allSatisfy { $0.values.count == 1 }, "Missing or duplicate Find completion: \(pending.map(\.detail))")
            }
            func expect(_ receipt: FindReceipt, _ found: Bool) throws {
                try require(receipt.values == [found], "Unexpected Find result: \(receipt.detail); expected \(found)")
            }

            let initial = submit("initial-hit", "NousFindAlpha42")
            try await wait([initial]); try expect(initial, true)
            for index in 1...3 {
                let repeated = submit("repeat-same-text-next-false-\(index)", "NousFindAlpha42")
                try await wait([repeated]); try expect(repeated, true)
            }

            // All requests are issued in the same main-loop turn. Only the
            // latest should retain its completion while CEF processes one find.
            let burst = [
                submit("burst-alpha", "NousFindAlpha42"),
                submit("burst-beta", "NousFindBeta42"),
                submit("burst-missing", "NousFindMissing999"),
                submit("burst-beta-again", "NousFindBeta42"),
                submit("burst-next", "NousFindBeta42", next: true),
                submit("burst-final-previous", "NousFindBeta42", next: true, backwards: true)
            ]
            try await wait(burst)
            for superseded in burst.dropLast() { try expect(superseded, false) }
            try expect(burst.last!, true)

            let stopped = [submit("stop-active", "NousFindAlpha42"), submit("stop-queued-next", "NousFindAlpha42", next: true)]
            view.stopFinding()
            try await wait(stopped)
            for receipt in stopped { try expect(receipt, false) }
            let afterStop = submit("fresh-hit-after-stop", "NousFindBeta42")
            try await wait([afterStop]); try expect(afterStop, true)
            let missing = submit("no-match", "NousFindMissing999")
            try await wait([missing]); try expect(missing, false)
            let recovered = submit("new-hit-after-no-match", "NousFindAlpha42")
            try await wait([recovered]); try expect(recovered, true)
            try await Task.sleep(for: .milliseconds(250))
            try require(receipts.allSatisfy { $0.values.count == 1 }, "A late Find result completed an old request twice: \(receipts.map(\.detail))")
            return ["requests": receipts.map(\.detail), "nativeCEFReplies": true,
                    "requestTimeoutMilliseconds": 5_000,
                    "coverage": ["same-query-fresh-search", "rapid-query-next-previous", "stop-active-and-queued", "no-match-then-new-hit"],
                    "limit": "Navigation/close cancellation and native Find bar keyboard interaction require their own lifecycle checks."]
        }

        /// More than eight visited pages must detach the oldest native view,
        /// without destroying its renderer, unsaved input or navigation state.
        func backgroundRetention(in context: BrowserWindowContext, preserving original: BrowserTab) async throws -> [String: Any] {
            var phase = "create retained tab"
            do {
            let model = context.controller.model
            var created: [UUID] = []
            defer {
                model.selectTab(original.id)
                for id in created { model.closeTab(id) }
            }
            context.window.makeKeyAndOrderFront(nil)
            model.newTab(url: base.appendingPathComponent("page2"))
            guard let target = model.selectedTab, target.id != original.id else { throw Failure("Cannot create retention fixture") }
            created.append(target.id)
            context.controller.dismissAddress()
            let view = target.webView
            try await waitForPage(view, path: "/page2")
            _ = try await view.evaluateScript(#"""
            (()=>{const marker=crypto.randomUUID();globalThis.__nousRetention={marker,object:{value:42}};
              document.body.replaceChildren();document.body.style.cssText='margin:0;min-height:4000px';
              const input=document.createElement('textarea');input.id='retention-input';input.value='unsaved synthetic text 中文';
              document.body.append(input);input.setSelectionRange(3,12);
              scrollTo(0,540);history.replaceState({marker,step:'a'},'','#retention-a');
              history.pushState({marker,step:'b'},'','#retention-b');return true})()
            """#, world: "")
            try await Task.sleep(for: .milliseconds(100))
            let stateScript = #"""
            (()=>{const input=document.getElementById('retention-input');return {
              marker:globalThis.__nousRetention?.marker,objectValue:globalThis.__nousRetention?.object.value,
              text:input?.value,selectionStart:input?.selectionStart,selectionEnd:input?.selectionEnd,
              scrollY,historyLength:history.length,historyMarker:history.state?.marker,
              historyStep:history.state?.step,hash:location.hash}})()
            """#
            let before = try dictionary(await view.evaluateScript(stateScript, world: ""))
            let navigationID = view.navigationID
            var navigations = 0
            let observer = view.addEventObserver { event, _ in if event == "load-start" { navigations += 1 } }
            defer { view.removeEventObserver(observer) }
            phase = "open additional tabs"
            let extraTabCount = WebViewDeckView.attachedLimit + 2
            for _ in 0..<extraTabCount {
                model.newTab(url: base.appendingPathComponent("page2"))
                guard let added = model.selectedTab, !created.contains(added.id) else { throw Failure("Could not create enough visited fixture tabs") }
                created.append(added.id)
                context.controller.dismissAddress()
                try await waitForPage(added.webView, path: "/page2")
            }
            for _ in 0..<30 {
                if view.superview == nil && view.window == nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(view.superview == nil && view.window == nil, "Oldest visited page did not exercise native deck detachment")
            phase = "read detached page"
            let detached = try dictionary(await view.evaluateScript(stateScript, world: ""))
            model.selectTab(target.id)
            for _ in 0..<30 {
                if view.window === context.window && !view.isHidden { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(view.window === context.window && !view.isHidden, "Detached page did not reattach on selection")
            try await Task.sleep(for: .milliseconds(100))
            phase = "read reattached page"
            let after = try dictionary(await view.evaluateScript(stateScript, world: ""))
            for state in [detached, after] {
                for key in ["marker", "text", "historyMarker", "historyStep", "hash"] {
                    try require(state[key] as? String == before[key] as? String && before[key] is String,
                                "Retained page lost \(key): \(state)")
                }
                for key in ["objectValue", "selectionStart", "selectionEnd", "historyLength"] {
                    try require((state[key] as? NSNumber)?.intValue == (before[key] as? NSNumber)?.intValue && before[key] is NSNumber,
                                "Retained page changed \(key): \(state)")
                }
            }
            let initialScroll = (before["scrollY"] as? NSNumber)?.doubleValue ?? -1
            let restoredScroll = (after["scrollY"] as? NSNumber)?.doubleValue ?? -2
            try require(initialScroll >= 500 && abs(initialScroll - restoredScroll) <= 1,
                        "Scroll offset was not preserved: \(initialScroll) → \(restoredScroll)")
            try require(view.navigationID == navigationID && navigations == 0, "Selecting a detached tab reloaded its document")

            func waitForHistory(_ step: String) async throws {
                for _ in 0..<30 {
                    if try await view.evaluateScript("history.state?.step", world: "") as? String == step { return }
                    try await Task.sleep(for: .milliseconds(50))
                }
                throw Failure("Retained navigation history did not reach step \(step)")
            }
            // These history entries were created by synthetic script, without
            // user activation. Chromium's native Back correctly skips such
            // entries to prevent history hijacking. Exercise exact same-document
            // history here; native Back is verified separately with real clicks.
            phase = "script history back after reattachment"
            _ = try await view.evaluateScript("history.back();true", world: "")
            try await waitForHistory("a")
            phase = "script history forward after reattachment"
            _ = try await view.evaluateScript("history.forward();true", world: "")
            try await waitForHistory("b")
            let afterHistory = try dictionary(await view.evaluateScript(stateScript, world: ""))
            try require(afterHistory["marker"] as? String == before["marker"] as? String &&
                        afterHistory["text"] as? String == before["text"] as? String && navigations == 0,
                        "Back/forward after reattachment lost the live page")
            return ["extraVisitedTabs": extraTabCount, "deckAttachmentLimit": WebViewDeckView.attachedLimit,
                    "nativeDetachmentObserved": true, "loadStartEvents": navigations,
                    "before": before, "detached": detached, "reattached": after,
                    "backForwardRetained": true,
                    "historyTraversal": "script history.back/forward (synthetic entries have no user activation)",
                    "limit": "This tests live retention, not Memory Saver discard, trusted editing protection or native Back-button semantics."]
            } catch { throw Failure("\(phase): \(error)") }
        }

        /// Both window-selected tabs must retain their live contents when one is
        /// non-key and when it is minimized. Only harness-created pages are used.
        func selectedWindowRetention(in first: BrowserWindowContext, preserving original: BrowserTab) async throws -> [String: Any] {
            let model = first.controller.model
            model.newTab(url: base.appendingPathComponent("page2"))
            guard let firstTab = model.selectedTab, firstTab.id != original.id else { throw Failure("Cannot create first window fixture") }
            first.controller.dismissAddress()
            var second: BrowserWindowContext?
            defer {
                if first.window.isMiniaturized { first.window.deminiaturize(nil) }
                model.selectTab(original.id)
                model.closeTab(firstTab.id)
                if let second { windows.closeWindow(second.session.id) }
                first.window.makeKeyAndOrderFront(nil)
            }
            try await waitForPage(firstTab.webView, path: "/page2")
            _ = try await firstTab.webView.evaluateScript("globalThis.__nousSelectedWindow='first-window-live';true", world: "")
            let firstNavigation = firstTab.webView.navigationID
            guard let createdWindow = windows.newWindow(), let secondTab = createdWindow.controller.model.selectedTab else {
                throw Failure("Cannot create second synthetic window")
            }
            second = createdWindow
            createdWindow.controller.dismissAddress()
            secondTab.load(base.appendingPathComponent("page2"))
            try await waitForPage(secondTab.webView, path: "/page2")
            _ = try await secondTab.webView.evaluateScript("globalThis.__nousSelectedWindow='second-window-live';true", world: "")
            let secondNavigation = secondTab.webView.navigationID
            createdWindow.window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            try require(createdWindow.window.isKeyWindow && !first.window.isKeyWindow,
                        "Two-window check did not exercise a non-key selected page")
            try require(model.selectedTab?.id == firstTab.id && createdWindow.controller.model.selectedTab?.id == secondTab.id,
                        "Activating another window changed its peer's selected tab")
            let firstNonKey = try await firstTab.webView.evaluateScript("globalThis.__nousSelectedWindow", world: "") as? String
            first.window.miniaturize(nil)
            for _ in 0..<30 {
                if first.window.isMiniaturized { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try require(first.window.isMiniaturized, "Could not exercise a minimized selected page")
            let firstMinimized = try await firstTab.webView.evaluateScript("globalThis.__nousSelectedWindow", world: "") as? String
            try require(model.selectedTab?.id == firstTab.id, "Minimizing a window changed its selected tab")
            first.window.deminiaturize(nil)
            first.window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            let firstRestored = try await firstTab.webView.evaluateScript("globalThis.__nousSelectedWindow", world: "") as? String
            let secondNonKey = try await secondTab.webView.evaluateScript("globalThis.__nousSelectedWindow", world: "") as? String
            try require(firstNonKey == "first-window-live" && firstMinimized == firstNonKey && firstRestored == firstNonKey &&
                        secondNonKey == "second-window-live", "Window activation/minimization discarded a selected live document")
            try require(firstTab.webView.navigationID == firstNavigation && secondTab.webView.navigationID == secondNavigation,
                        "A window-selected page reloaded during activation/minimization")
            return ["nonKeySelectedRetained": true, "minimizedSelectedRetained": true, "secondWindowSelectedRetained": true,
                    "nativeTabLifecycleAvailable": NBChromiumRuntime.hasNativeTabLifecycle(),
                    "limit": "Selection and live retention are verified; protection against an actual PROACTIVE discard must be tested with the custom framework and chrome://discards."]
        }

        /// Starts a real background link without ever mounting/selecting it.
        /// The first parser script records visibility before any async probe.
        func neverSelectedBackground(in context: BrowserWindowContext, preserving original: BrowserTab) async throws -> [String: Any] {
            let model = context.controller.model
            context.window.makeKeyAndOrderFront(nil)
            model.selectTab(original.id)
            guard let target = model.openLinkInNewTab(base.appendingPathComponent("never-selected"), after: original.id, activate: false) else {
                throw Failure("Could not open a background fixture link")
            }
            defer { model.selectTab(original.id); model.closeTab(target.id) }
            try require(model.selectedTabID == original.id, "Background link changed source selection")
            try await waitForPage(target.webView, path: "/never-selected")
            let script = "({...window.__nousNeverSelected,visibilityNow:document.visibilityState,hiddenNow:document.hidden,readyNow:document.readyState,navigationEntries:performance.getEntriesByType('navigation').length})"
            let initial = try dictionary(await target.webView.evaluateScript(script, world: ""))
            try require(initial["initialVisibility"] as? String == "hidden" && initial["initialHidden"] as? Bool == true,
                        "Never-selected page started visible: \(initial)")
            try require(initial["initialReadyState"] as? String == "loading", "Fixture did not observe parser-time visibility")
            try require(initial["readyNow"] as? String == "complete" && model.selectedTabID == original.id,
                        "Background page did not fully load while source remained selected")
            var hidden = initial
            for _ in 0..<80 {
                if hidden["longTimer"] as? [String: Any] != nil { break }
                try await Task.sleep(for: .milliseconds(100))
                hidden = try dictionary(await target.webView.evaluateScript(script, world: ""))
            }
            let longTimer = hidden["longTimer"] as? [String: Any]
            try require(longTimer?["visibility"] as? String == "hidden" && (longTimer?["elapsed"] as? Double ?? 0) >= 1_100,
                        "A background long timer did not run while hidden: \(hidden)")
            try require(hidden["visibilityNow"] as? String == "hidden" && hidden["hiddenNow"] as? Bool == true &&
                        (hidden["rafCount"] as? Int ?? -1) == 0 && model.selectedTabID == original.id,
                        "Never-selected page animated or became selected/visible: \(hidden)")
            model.selectTab(target.id)
            var selected: [String: Any] = [:]
            for _ in 0..<40 {
                selected = try dictionary(await target.webView.evaluateScript(script, world: ""))
                if selected["visibilityNow"] as? String == "visible" && (selected["rafCount"] as? Int ?? 0) >= 2 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(selected["loadID"] as? String == initial["loadID"] as? String && selected["loadID"] as? String != nil,
                        "First selection reloaded the background page")
            try require(selected["visibilityNow"] as? String == "visible" && (selected["rafCount"] as? Int ?? 0) >= 2,
                        "First selection did not resume native visibility/animation: \(selected)")
            return ["documentStart": initial, "beforeSelection": hidden, "afterSelection": selected,
                    "sourceRemainedSelected": true, "retainedLoadID": true,
                    "limit": "Timer timestamps are observed, not asserted as Chrome's long-duration intensive-throttling policy."]
        }

        /// Selects real model tabs so WebViewDeck must apply native visibility.
        /// No CDP lifecycle/visibility override and no synthetic DOM event is used.
        func backgroundScheduling(in context: BrowserWindowContext, tab: BrowserTab) async throws -> [String: Any] {
            let model = context.controller.model
            let view = tab.webView
            var backgroundTabID: UUID?
            var samples: [[String: Any]] = []
            defer {
                model.selectTab(tab.id)
                if let backgroundTabID { model.closeTab(backgroundTabID) }
                Task { @MainActor in
                    _ = try? await view.evaluateScript("if(globalThis.__nousRAF){__nousRAF.running=false;cancelAnimationFrame(__nousRAF.request)};true", world: "")
                }
            }
            func sample(_ phase: String) async throws -> [String: Any] {
                var value = try dictionary(await view.evaluateScript("({visibility:document.visibilityState,hidden:document.hidden,count:globalThis.__nousRAF?.count??0,events:globalThis.__nousRAF?.visibility??[]})", world: ""))
                value["phase"] = phase
                samples.append(value)
                return value
            }
            func waitForVisibility(_ expected: String) async throws {
                for _ in 0..<30 {
                    if try await view.evaluateScript("document.visibilityState", world: "") as? String == expected { return }
                    try await Task.sleep(for: .milliseconds(100))
                }
                _ = try await sample("visibility-timeout-\(expected)")
                throw Failure("Native deck did not set \(expected): \(samples)")
            }
            func count(_ sample: [String: Any]) -> Int { (sample["count"] as? NSNumber)?.intValue ?? 0 }

            context.window.makeKeyAndOrderFront(nil)
            model.selectTab(tab.id)
            try await waitForVisibility("visible")
            _ = try await view.evaluateScript(#"""
            (()=>{const state={count:0,running:true,request:0,visibility:[]};globalThis.__nousRAF=state;
            const tick=()=>{if(!state.running)return;state.count++;state.request=requestAnimationFrame(tick)};
            document.addEventListener('visibilitychange',()=>state.visibility.push({state:document.visibilityState,count:state.count,at:performance.now()}));
            state.request=requestAnimationFrame(tick);return true})()
            """#, world: "")
            let visibleStart = try await sample("visible-start")
            try await Task.sleep(for: .milliseconds(700))
            let visibleEnd = try await sample("visible-end")
            try require(count(visibleEnd) - count(visibleStart) >= 2, "Foreground animation did not run: \(samples)")

            model.newTab(url: base.appendingPathComponent("page2"))
            guard let background = model.selectedTab, background.id != tab.id else {
                throw Failure("Native deck did not select a second synthetic tab")
            }
            backgroundTabID = background.id
            context.controller.dismissAddress()
            try await waitForPage(background.webView, path: "/page2")
            try await waitForVisibility("hidden")
            // Allow a previously queued frame to settle before measuring hidden time.
            try await Task.sleep(for: .milliseconds(250))
            let hiddenStart = try await sample("hidden-start")
            try await Task.sleep(for: .milliseconds(900))
            let hiddenEnd = try await sample("hidden-end")
            let hiddenDelta = count(hiddenEnd) - count(hiddenStart)
            try require(hiddenEnd["visibility"] as? String == "hidden" && hiddenEnd["hidden"] as? Bool == true && hiddenDelta <= 1,
                        "Background rAF continued or document remained visible: \(samples)")

            model.selectTab(tab.id)
            try await waitForVisibility("visible")
            let resumedStart = try await sample("resumed-start")
            try await Task.sleep(for: .milliseconds(700))
            let resumedEnd = try await sample("resumed-end")
            let resumedDelta = count(resumedEnd) - count(resumedStart)
            try require(resumedDelta >= 2, "Animation did not resume on native tab selection: \(samples)")
            return ["samples": samples, "hiddenFrameDelta": hiddenDelta, "resumedFrameDelta": resumedDelta,
                    "hiddenObservationMilliseconds": 900, "nativeTabSelection": true,
                    "limit": "This proves hidden-page animation scheduling only, not sustained Zoom editing performance."]
        }

        #if DEBUG
        func passwordChecks() async {
            let view = ChromiumPageView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Nous Chromium — Synthetic password fixture"
            window.isReleasedWhenClosed = false
            window.contentView = view
            var candidate: BrowserPasswordAutofill.Candidate?
            let attachment = ChromiumPasswordAutofill.attach(to: view, allowLoopbackHTTPForTesting: true) { candidate = $0 }
            window.makeKeyAndOrderFront(nil)
            defer { attachment.invalidate(); view.shutdown(); window.close() }
            await check("password-candidate-and-fill") {
                view.load(URLRequest(url: self.base.appendingPathComponent("login")))
                try await self.waitForPage(view, path: "/login")
                for _ in 0..<40 {
                    if candidate != nil { break }; try await Task.sleep(for: .milliseconds(100))
                }
                guard let target = candidate else { throw Failure("Synthetic login candidate was not reported") }
                // Native state/load-end handshakes can overlap. Re-request the
                // metadata through the real isolated engine, then use the token
                // already shown to native UI; unchanged forms must keep it valid.
                for _ in 0..<3 {
                    _ = try await view.evaluateScript(ChromiumPasswordAutofill.refreshSource, world: ChromiumPasswordAutofill.world)
                }
                _ = try await BrowserPasswordAutofill.fill(.init(username: "fixture@example.test", password: "synthetic-only-秘密-'\"\\"), in: view, expectedOrigin: target.origin, token: target.token)
                let response = try self.dictionary(await view.evaluateScript("({username:document.getElementById('username').value,password:document.getElementById('password').value,events:fixtureEvents})", world: ""))
                try self.require(response["username"] as? String == "fixture@example.test" && response["password"] as? String == "synthetic-only-秘密-'\"\\", "Synthetic credentials did not reach exact fields")
                let events = response["events"] as? [String: Any] ?? [:]
                try self.require(events["submit"] as? Int == 0, "Autofill submitted the form")
                return ["filledExactSyntheticValues": true, "events": events,
                        "repeatedMetadataRefreshes": 3, "originalTokenRemainedValid": true]
            }
            await check("password-navigation-token-rejected") {
                candidate = nil
                view.load(URLRequest(url: self.base.appendingPathComponent("login")))
                try await self.waitForPage(view, path: "/login")
                for _ in 0..<40 { if candidate != nil { break }; try await Task.sleep(for: .milliseconds(100)) }
                guard let previous = candidate else { throw Failure("Initial candidate missing") }
                candidate = nil
                view.load(URLRequest(url: self.base.appendingPathComponent("alternate")))
                try await self.waitForPage(view, path: "/alternate")
                for _ in 0..<40 { if candidate != nil { break }; try await Task.sleep(for: .milliseconds(100)) }
                guard let current = candidate else { throw Failure("New document candidate missing") }
                try self.require(previous.token != current.token, "A navigation reused the old password token")
                var rejected = false
                do { _ = try await BrowserPasswordAutofill.fill(.init(username: "fixture@example.test", password: "must-not-fill"), in: view, expectedOrigin: previous.origin, token: previous.token) }
                catch BrowserPasswordAutofill.Failure.staleDocument { rejected = true }
                let password = try await view.evaluateScript("document.getElementById('password').value", world: "") as? String
                try self.require(rejected && password == "", "A stale document token received credentials")
                return ["tokenChanged": true, "staleTokenRejected": true]
            }
            await check("password-cross-origin-action-rejected") {
                candidate = nil
                view.load(URLRequest(url: self.base.appendingPathComponent("cross-action")))
                try await self.waitForPage(view, path: "/cross-action")
                try await Task.sleep(for: .milliseconds(350))
                try self.require(candidate == nil, "A cross-origin action became an autofill candidate")
                return ["candidateRejected": true]
            }
            await check("password-action-mutation-rejected") {
                candidate = nil
                view.load(URLRequest(url: self.base.appendingPathComponent("mutate-on-username")))
                try await self.waitForPage(view, path: "/mutate-on-username")
                for _ in 0..<40 { if candidate != nil { break }; try await Task.sleep(for: .milliseconds(100)) }
                guard let target = candidate else { throw Failure("Mutation fixture candidate missing") }
                var rejected = false
                do { _ = try await BrowserPasswordAutofill.fill(.init(username: "fixture@example.test", password: "must-not-fill"), in: view, expectedOrigin: target.origin, token: target.token) }
                catch BrowserPasswordAutofill.Failure.staleDocument { rejected = true }
                let password = try await view.evaluateScript("document.getElementById('password').value", world: "") as? String
                try self.require(rejected && password == "", "Unsafe action mutation received a password")
                return ["rejected": true, "passwordFieldEmpty": true]
            }
        }
        #endif
    }
}
