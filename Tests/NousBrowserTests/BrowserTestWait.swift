import Foundation
import Testing

/// AppKit/CEF close acknowledgements are asynchronous. Wait for the observable
/// outcome instead of assuming synchronous teardown or sleeping for a
/// fixed duration. No engine, browser window or user profile is started here.
@MainActor
func waitForBrowserTest(_ condition: () -> Bool,
                        sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition(), "The browser did not complete its state transition", sourceLocation: sourceLocation)
}
