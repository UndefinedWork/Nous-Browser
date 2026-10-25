import AppKit
import SwiftUI

@MainActor
enum SidebarDragDiagnostics {
    #if DEBUG
    static let enabled = ProcessInfo.processInfo.environment["NOUS_BROWSER_PREVIEW_SESSION"] != nil
        && ProcessInfo.processInfo.environment["NOUS_BROWSER_DRAG_DIAGNOSTICS"] == "1"
    #else
    static let enabled = false
    #endif

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard enabled else { return }
        FileHandle.standardOutput.write(Data(("[NousDrag] " + message() + "\n").utf8))
        #endif
    }
}

enum SidebarTabDragGeometry {
    static let coordinateSpace = "nous-browser-sidebar-viewport"
    static let contentInset: CGFloat = 68
    static let rowSpacing: CGFloat = 1
    static var stride: CGFloat { BrowserDesign.rowHeight + rowSpacing }
}

struct SidebarTabFramePreference: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

struct SidebarScrollMetrics: Equatable {
    var offsetY: CGFloat = 0
    var maximumOffsetY: CGFloat = 0

    init() {}

    init(_ geometry: ScrollGeometry) {
        offsetY = geometry.contentOffset.y + geometry.contentInsets.top
        maximumOffsetY = max(0, geometry.contentSize.height - geometry.containerSize.height
                            + geometry.contentInsets.top + geometry.contentInsets.bottom)
    }
}

struct SidebarTabDragSession {
    let token = UUID()
    let startedAt = ProcessInfo.processInfo.systemUptime
    let id: UUID
    let originalOrder: [UUID]
    let pinnedIDs: Set<UUID>
    let sourceRect: CGRect
    let grabOffsetY: CGFloat
    let initialPointer: CGPoint
    var pointer: CGPoint
    var center: CGPoint
    var changedEvents = 0
    var isSettling = false
}

/// Recognizes only a drag; ordinary clicks and the row's double-click still work.
struct SidebarTabDragGesture: ViewModifier {
    let onChanged: (DragGesture.Value) -> Void
    let onEnded: (DragGesture.Value) -> Void
    let onCancelled: () -> Void
    @GestureState private var gestureActive = false

    func body(content: Content) -> some View {
        content
            .highPriorityGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(SidebarTabDragGeometry.coordinateSpace))
                    .updating($gestureActive) { _, active, _ in active = true }
                    .onChanged(onChanged)
                    .onEnded(onEnded)
            )
            .onChange(of: gestureActive) { wasActive, active in
                if wasActive && !active {
                    // onEnded gets the first chance to commit a normal release.
                    Task { @MainActor in
                        await Task.yield()
                        onCancelled()
                    }
                }
            }
    }
}

struct SidebarTabFavicon: View {
    let tab: BrowserTab

    var body: some View {
        Group {
            if let favicon = tab.favicon {
                Image(nsImage: favicon)
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: tab.url == nil ? "sparkle" : "globe")
                    .font(.system(size: 12, weight: .regular))
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

struct SidebarFloatingTab: View {
    let tab: BrowserTab
    let isSettling: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var lifted = false

    var body: some View {
        HStack(spacing: 7) {
            SidebarTabFavicon(tab: tab)
            Text(tab.displayTitle)
                .font(.system(size: 12, weight: .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 16)
            if tab.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 10, height: 12)
            }
        }
        .foregroundStyle(colorScheme == .dark ? Color.primary : Color(white: 0.176))
        .padding(.horizontal, 12)
        .frame(height: BrowserDesign.rowHeight)
        .background((colorScheme == .dark ? Color(white: 0.22) : Color.white).opacity(0.96), in: Capsule())
        .shadow(color: .black.opacity(isSettling || !lifted ? (colorScheme == .dark ? 0.08 : 0.04) : (colorScheme == .dark ? 0.22 : 0.13)), radius: isSettling || !lifted ? 2 : 10, y: isSettling || !lifted ? 1 : 4)
        .scaleEffect(reduceMotion || isSettling || !lifted ? 1 : 1.025)
        .animation(reduceMotion ? nil : BrowserMotion.interaction, value: lifted)
        .onAppear { lifted = true }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Common run-loop modes keep edge scrolling alive during native mouse tracking.
struct SidebarEdgeAutoScrollDriver: NSViewRepresentable {
    let isActive: Bool
    let onTick: (Int) -> Void

    func makeNSView(context: Context) -> TimerView {
        SidebarDragDiagnostics.log("driver.created")
        return TimerView()
    }

    func updateNSView(_ view: TimerView, context: Context) {
        view.onTick = onTick
        view.setActive(isActive)
    }

    static func dismantleNSView(_ view: TimerView, coordinator: ()) { view.setActive(false) }

    final class TimerView: NSView {
        var onTick: ((Int) -> Void)?
        private var timer: Timer?
        private var tickCount = 0
        private var startedAt: TimeInterval = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            SidebarDragDiagnostics.log("driver.mount attached=\(window != nil) active=\(timer != nil) nativeScrollAncestor=\(enclosingScrollView != nil)")
            if window == nil { setActive(false) }
        }

        func setActive(_ active: Bool) {
            if !active {
                if timer != nil {
                    SidebarDragDiagnostics.log("timer.stop ticks=\(tickCount) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))")
                }
                timer?.invalidate()
                timer = nil
                return
            }
            guard timer == nil else { return }
            tickCount = 0
            startedAt = ProcessInfo.processInfo.systemUptime
            SidebarDragDiagnostics.log("timer.start attached=\(window != nil) mode=\(RunLoop.current.currentMode?.rawValue ?? "none")")
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.tickCount += 1
                    if self.tickCount == 1 || self.tickCount.isMultiple(of: 30) {
                        SidebarDragDiagnostics.log("timer.tick count=\(self.tickCount) attached=\(self.window != nil) mode=\(RunLoop.current.currentMode?.rawValue ?? "none")")
                    }
                    self.onTick?(self.tickCount)
                }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}

/// Escape must cancel even when a WKWebView still owns first responder.
struct SidebarDragCancellationMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let canCancel: Bool
    let onCancel: () -> Void
    let onPointerRelease: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.canCancel = canCancel
        view.onCancel = onCancel
        view.onPointerRelease = onPointerRelease
        view.setEnabled(isEnabled)
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.setEnabled(false) }

    final class MonitorView: NSView {
        var canCancel = false
        var onCancel: (() -> Void)?
        var onPointerRelease: (() -> Void)?
        private var eventMonitor: Any?
        private var resignObserver: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func setEnabled(_ enabled: Bool) {
            if !enabled {
                if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
                if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
                eventMonitor = nil
                resignObserver = nil
                return
            }
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp, .leftMouseDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    if event.type == .keyDown, event.keyCode == 53, self.canCancel {
                        self.onCancel?()
                        return true
                    }
                    if event.type == .leftMouseUp || event.type == .leftMouseDown {
                        self.onPointerRelease?()
                    }
                    return false
                }
                return consumed ? nil : event
            }
            // The drag starts only after this view is attached. Scoping the
            // observer also avoids transferring Notification across actors.
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                    object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.canCancel else { return }
                    self.onCancel?()
                }
            }
        }
    }
}
