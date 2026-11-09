import Foundation
import Testing
@testable import NousBrowser

@Suite("Compact sidebar tooltip timing", .serialized)
@MainActor
struct SidebarTabTooltipTests {
    /// Poll only for eventual delivery. Timing assertions use a monotonic clock,
    /// so an overloaded runner cannot fail merely by waking later than expected.
    private func waitForPresentation(_ state: SidebarTabTooltipState) async throws -> SidebarTabTooltipState.Presentation {
        let deadline = ContinuousClock.now + .seconds(2)
        while state.presented == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return try #require(state.presented)
    }

    @Test func defaultHoverWaitsAtLeastThreeHundredMilliseconds() async throws {
        let state = SidebarTabTooltipState()
        let id = UUID()
        let started = ContinuousClock.now
        state.hover(tabID: id, title: "Quarterly plan", centerY: 122)
        #expect(state.presented == nil)
        #expect(state.hoveredTabID == id)
        #expect(state.isTracking)

        let presentation = try await waitForPresentation(state)
        #expect(started.duration(to: .now) >= .milliseconds(300))
        #expect(presentation == .init(tabID: id, title: "Quarterly plan", centerY: 122))
        state.dismiss()
    }

    @Test func injectedDelayStillDefersPresentationUntilItElapses() async throws {
        let state = SidebarTabTooltipState(delay: .milliseconds(35))
        let started = ContinuousClock.now
        state.hover(tabID: UUID(), title: "Short delay", centerY: 159)
        #expect(state.presented == nil)
        _ = try await waitForPresentation(state)
        #expect(started.duration(to: .now) >= .milliseconds(35))
        state.dismiss()
    }

    @Test func leavingBeforeDelayCancelsThePendingTooltip() async throws {
        let state = SidebarTabTooltipState(delay: .milliseconds(30))
        let id = UUID()
        state.hover(tabID: id, title: "Do not show", centerY: 122)
        state.leave(tabID: id)
        #expect(!state.isTracking)
        #expect(state.hoveredTabID == nil)

        // Yield beyond the old task's deadline; a cancelled hover must not
        // reappear after the pointer has already left its icon.
        try await Task.sleep(for: .milliseconds(70))
        #expect(state.presented == nil)
        #expect(!state.isTracking)
    }

    @Test func lateExitFromPreviousRowDoesNotCancelTheNewRow() async throws {
        let state = SidebarTabTooltipState(delay: .milliseconds(25))
        let first = UUID(), second = UUID()
        state.hover(tabID: first, title: "First", centerY: 122)
        state.hover(tabID: second, title: "Second", centerY: 159)
        state.leave(tabID: first)
        #expect(state.hoveredTabID == second)

        let presentation = try await waitForPresentation(state)
        #expect(presentation == .init(tabID: second, title: "Second", centerY: 159))
        // The same stale exit is harmless after the new tooltip is visible.
        state.leave(tabID: first)
        #expect(state.presented == presentation)
        state.leave(tabID: second)
        #expect(state.presented == nil)
        #expect(!state.isTracking)
    }

    @Test func revisitingTheSameIDCannotReviveItsCancelledPresentation() async throws {
        let state = SidebarTabTooltipState(delay: .milliseconds(25))
        let id = UUID()
        state.hover(tabID: id, title: "Before scrolling", centerY: 122)
        state.dismiss()
        state.hover(tabID: id, title: "After scrolling", centerY: 85)

        let presentation = try await waitForPresentation(state)
        #expect(presentation == .init(tabID: id, title: "After scrolling", centerY: 85))
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.presented == presentation)
        state.dismiss()
    }

    @Test func dismissingAVisibleTooltipClearsTrackingAndDoesNotReshow() async throws {
        let state = SidebarTabTooltipState(delay: .zero)
        state.hover(tabID: UUID(), title: "Visible", centerY: 196)
        _ = try await waitForPresentation(state)
        state.dismiss()
        #expect(state.presented == nil)
        #expect(state.hoveredTabID == nil)
        #expect(!state.isTracking)
        try await Task.sleep(for: .milliseconds(30))
        #expect(state.presented == nil)
    }
}
