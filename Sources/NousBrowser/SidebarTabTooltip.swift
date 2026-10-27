import AppKit
import Observation
import SwiftUI

/// A single cancellable hover per window prevents late tooltips from old rows.
@MainActor
@Observable
final class SidebarTabTooltipState {
    struct Presentation: Equatable {
        let tabID: UUID
        let title: String
        let centerY: CGFloat
    }

    private(set) var presented: Presentation?
    private(set) var hoveredTabID: UUID?
    var isTracking: Bool { hoveredTabID != nil }
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private let delay: Duration

    init(delay: Duration = .milliseconds(300)) { self.delay = delay }

    func hover(tabID: UUID, title: String, centerY: CGFloat) {
        guard hoveredTabID != tabID else { return }
        dismiss()
        hoveredTabID = tabID
        let delay = delay
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self, self.hoveredTabID == tabID else { return }
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : BrowserMotion.interaction) {
                self.presented = Presentation(tabID: tabID, title: title, centerY: centerY)
            }
            self.pending = nil
        }
    }

    func leave(tabID: UUID) {
        // Moving between adjacent rows can deliver their exit/entry out of order.
        guard hoveredTabID == tabID else { return }
        dismiss()
    }

    func dismiss() {
        pending?.cancel()
        pending = nil
        hoveredTabID = nil
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : BrowserMotion.interaction) {
            presented = nil
        }
    }

    deinit { pending?.cancel() }
}

struct SidebarTabTooltip: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .glassEffect(.regular, in: Capsule())
            .shadow(color: .black.opacity(0.08), radius: 12, y: 8)
    }
}

/// Compact rows use the 300 ms glass tooltip instead of a second AppKit tooltip.
struct SidebarTabHelp: ViewModifier {
    let isCompact: Bool
    let text: String
    func body(content: Content) -> some View {
        if isCompact { content } else { content.help(text) }
    }
}

/// Observe, never consume, native input. Right-click dismisses before the menu
/// takes over tracking; window deactivation also cancels a pending hover.
struct SidebarTooltipDismissalMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let dismiss: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) {
        view.dismiss = dismiss
        view.setEnabled(isEnabled)
    }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.setEnabled(false) }

    final class MonitorView: NSView {
        var dismiss: (() -> Void)?
        private var monitor: Any?
        private var observer: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func setEnabled(_ enabled: Bool) {
            guard enabled else {
                if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
                if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
                if let self, self.window != nil, event.window === self.window { self.dismiss?() }
                return event
            }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
                let resignedWindow = note.object as? NSWindow
                MainActor.assumeIsolated {
                    if let self, resignedWindow === self.window { self.dismiss?() }
                }
            }
        }
    }
}
