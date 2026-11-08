import AppKit
import NousCore
import SwiftUI

/// Picture-in-Picture in the iOS manner: Chromium's floating window shows the
/// video, and a transparent panel above it carries Liquid Glass controls —
/// close, back to the page, skip 10 seconds either way, play/pause and a
/// scrubbable progress bar. The controls appear while the pointer is over the
/// video and fade away while it plays.
@MainActor
final class PictureInPicturePlayer {
    static let shared = PictureInPicturePlayer()

    /// Brings the page the video came from to the front.
    var revealPage: ((NSView) -> Void)?
    private var overlays: [ObjectIdentifier: PictureInPictureOverlay] = [:]

    func start() {
        NBPictureInPictureCenter.shared().sessionHandler = { [weak self] session in
            MainActor.assumeIsolated { self?.attach(session) }
        }
    }

    private func attach(_ session: NBPictureInPictureSession) {
        guard let window = session.window else { return }
        let key = ObjectIdentifier(session)
        let overlay = PictureInPictureOverlay(session: session, video: window) { [weak self] in
            guard let self, let view = session.sourceView else { return }
            session.returnToPage()
            self.revealPage?(view)
        }
        overlays[key] = overlay
        session.closeHandler = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.overlays.removeValue(forKey: key)?.detach()
            }
        }
    }
}

// MARK: - Overlay window

@MainActor
private final class PictureInPictureOverlay {
    private let panel: NSPanel
    private weak var video: NSWindow?
    private let state: PictureInPictureState
    private var observers: [NSObjectProtocol] = []

    init(session: NBPictureInPictureSession, video: NSWindow, returnToPage: @escaping () -> Void) {
        self.video = video
        state = PictureInPictureState(session: session)
        panel = NSPanel(contentRect: video.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = video.level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true

        let root = PictureInPictureControls(state: state, returnToPage: returnToPage)
        let host = FirstMouseHostingView(rootView: root)
        host.dragWindow = video
        host.onPress = { [state] in state.reveal() }
        panel.contentView = host

        Self.roundCorners(of: video)
        video.addChildWindow(panel, ordered: .above)
        follow(video)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: video, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.follow(video) }
            })
        }
        panel.orderFront(nil)
    }

    static let cornerRadius: CGFloat = 16

    /// Chromium draws the window nearly square; give it the soft corners of
    /// a modern floating player, with a shadow that follows them.
    private static func roundCorners(of window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        for view in [window.contentView?.superview, window.contentView].compactMap({ $0 }) {
            view.wantsLayer = true
            view.layer?.cornerRadius = cornerRadius
            view.layer?.cornerCurve = .continuous
            view.layer?.masksToBounds = true
        }
        window.invalidateShadow()
    }

    /// Inset by a few points so the video window's own edges still resize it.
    private func follow(_ video: NSWindow) {
        panel.setFrame(video.frame.insetBy(dx: 4, dy: 4), display: true)
        panel.level = video.level
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        state.stop()
        video?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.close()
    }
}

/// Clicks work on the first press (the panel never becomes key), and a press
/// that no control takes moves the video window.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    weak var dragWindow: NSWindow?
    var onPress: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Like tapping a player on iOS: a press shows the controls, and dragging
    /// from it moves the window.
    override func mouseDown(with event: NSEvent) {
        onPress?()
        dragWindow?.performDrag(with: event)
    }
}

// MARK: - State

@MainActor
@Observable
private final class PictureInPictureState {
    @ObservationIgnored let session: NBPictureInPictureSession
    var isPlaying = true
    var hasEnded = false
    var duration: TimeInterval = 0
    /// When a click last asked for the controls.
    var revealedAt: Date?
    private var anchor: TimeInterval = 0
    private var anchorDate = Date()
    private var rate: Double = 1

    init(session: NBPictureInPictureSession) {
        self.session = session
        read()
        session.updateHandler = { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
    }

    private func read() {
        isPlaying = session.isPlaying
        hasEnded = session.hasEnded
        duration = session.duration
        anchor = session.position
        anchorDate = session.positionDate
        rate = session.playbackRate
    }

    func stop() { session.updateHandler = nil }

    func reveal() { revealedAt = Date() }

    /// A finite, known length: skipping and the progress bar make sense.
    var isSeekable: Bool { duration.isFinite && duration > 0 }

    func position(at date: Date) -> TimeInterval {
        let elapsed = isPlaying ? date.timeIntervalSince(anchorDate) * rate : 0
        let value = anchor + max(0, elapsed)
        return isSeekable ? min(max(0, value), duration) : max(0, value)
    }

    func togglePlayPause() {
        if hasEnded { session.seek(to: 0) }
        session.togglePlayPause()
        isPlaying.toggle()
    }

    func skip(_ seconds: TimeInterval) {
        session.seek(to: position(at: Date()) + seconds)
    }

    func seek(to seconds: TimeInterval) { session.seek(to: seconds) }
    func close() { session.close() }
}

// MARK: - Controls

private struct PictureInPictureControls: View {
    let state: PictureInPictureState
    let returnToPage: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var lastMove = Date()
    @State private var scrubbing: Double?

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 300 || geometry.size.height < 170
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                ZStack {
                    LinearGradient(colors: [.black.opacity(0.32), .black.opacity(0.12), .black.opacity(0.38)],
                                   startPoint: .top, endPoint: .bottom)
                    controls(compact: compact, now: context.date)
                }
                .clipShape(RoundedRectangle(cornerRadius: PictureInPictureOverlay.cornerRadius - 4, style: .continuous))
                .opacity(controlsShown(at: context.date) ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: controlsShown(at: context.date))
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active: hovering = true; lastMove = Date()
            case .ended: hovering = false
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private func controlsShown(at date: Date) -> Bool {
        if let revealed = state.revealedAt, date.timeIntervalSince(revealed) < 3 { return true }
        guard hovering else { return scrubbing != nil }
        return !state.isPlaying || state.hasEnded || scrubbing != nil || date.timeIntervalSince(lastMove) < 2.5
    }

    @ViewBuilder
    private func controls(compact: Bool, now: Date) -> some View {
        let edge: CGFloat = compact ? 10 : 14
        VStack(spacing: 0) {
            HStack {
                GlassIconButton(symbol: "xmark", size: compact ? 28 : 34, label: L10n.string("Close")) {
                    state.close()
                }
                Spacer()
                GlassIconButton(symbol: "pip.exit", size: compact ? 28 : 34, label: L10n.string("Back to Page")) {
                    returnToPage()
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: compact ? 18 : 30) {
                if state.isSeekable {
                    GlassIconButton(symbol: "gobackward.10", size: compact ? 38 : 50, label: L10n.string("Back 10 Seconds")) {
                        state.skip(-10)
                    }
                }
                GlassIconButton(symbol: state.hasEnded ? "arrow.counterclockwise" : state.isPlaying ? "pause.fill" : "play.fill",
                                size: compact ? 50 : 66,
                                label: L10n.string(state.isPlaying ? "Pause" : "Play")) {
                    state.togglePlayPause()
                }
                if state.isSeekable {
                    GlassIconButton(symbol: "goforward.10", size: compact ? 38 : 50, label: L10n.string("Forward 10 Seconds")) {
                        state.skip(10)
                    }
                }
            }
            Spacer(minLength: 0)
            if state.isSeekable && !compact {
                ProgressCapsule(state: state, now: now, scrubbing: $scrubbing)
            } else {
                Color.clear.frame(height: compact ? 0 : 34)
            }
        }
        .padding(edge)
    }
}

/// A round Liquid Glass control.
private struct GlassIconButton: View {
    let symbol: String
    let size: CGFloat
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Elapsed time, a draggable bar and the time remaining, in a glass capsule.
private struct ProgressCapsule: View {
    let state: PictureInPictureState
    let now: Date
    @Binding var scrubbing: Double?

    var body: some View {
        let position = scrubbing ?? state.position(at: now)
        let fraction = state.duration > 0 ? min(1, max(0, position / state.duration)) : 0
        HStack(spacing: 10) {
            Text(Self.format(position))
                .frame(minWidth: 34, alignment: .leading)
            GeometryReader { bar in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(0.9))
                        .frame(width: max(6, bar.size.width * fraction))
                }
                .frame(height: scrubbing == nil ? 6 : 9)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = min(max(0, value.location.x), bar.size.width)
                        scrubbing = Double(x / max(1, bar.size.width)) * state.duration
                    }
                    .onEnded { _ in
                        if let scrubbing { state.seek(to: scrubbing) }
                        scrubbing = nil
                    })
                .animation(.easeOut(duration: 0.15), value: scrubbing == nil)
            }
            Text("-" + Self.format(max(0, state.duration - position)))
                .frame(minWidth: 40, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 14)
        .frame(height: 34)
        .glassEffect(.regular, in: Capsule())
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
