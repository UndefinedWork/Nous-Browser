import AppKit
import Darwin
import Foundation
import Testing

/// A real AppKit host for the same Swift Testing cases used by swift test.
/// Only the autofill bridge and synthetic fixture tests are linked into this app.
@main
struct PasswordAutofillAppMain {
    @MainActor static func main() {
        setenv("NOUS_BROWSER_PASSWORD_AUTOFILL_TEST_HOST", "1", 1)
        let app = NSApplication.shared
        let delegate = PasswordAutofillTestDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        Darwin.exit(delegate.status)
    }
}

@MainActor
private final class PasswordAutofillTestDelegate: NSObject, NSApplicationDelegate {
    var status: CInt = 1
    private var watchdog: DispatchSourceTimer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 20)
        watchdog.setEventHandler {
            FileHandle.standardError.write(Data("Autofill integration host exceeded 20 seconds.\n".utf8))
            Darwin.exit(124)
        }
        watchdog.resume()
        self.watchdog = watchdog
        Task { @MainActor in
            var arguments = Testing.__CommandLineArguments_v0()
            arguments.parallel = false
            arguments.filter = ["BrowserPasswordAutofillTests"]
            arguments.xunitOutput = ProcessInfo.processInfo.environment["NOUS_BROWSER_PASSWORD_AUTOFILL_XUNIT"]
            let code: CInt = await Testing.__swiftPMEntryPoint(passing: arguments)
            status = code
            watchdog.cancel()
            NSApp.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(wake, atStart: true)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateCancel }
}
