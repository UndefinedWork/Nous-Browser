import AppKit
import AVFoundation
import Carbon
import Combine
import ScreenCaptureKit
import SwiftUI

// Adapted from Pico's recorder: the same selection overlay, setup bar, stop bar
// and ScreenCaptureKit pipeline. Nous adds a pointer track for the editor and
// hands the finished movie to a new editor tab instead of copying it.

struct RecordingTarget: Equatable {
    enum Kind: Equatable { case screen, area, window(CGWindowID) }
    var kind: Kind
    /// AppKit global points.
    var frame: CGRect
    var displayID: CGDirectDisplayID
}

struct PickableWindow: Equatable { let id: CGWindowID; let frame: CGRect }

extension NSScreen {
    var recordingDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

private struct RecordingFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Pointer positions (0…1, top-left origin of the recorded area) and clicks.
nonisolated struct CursorTrack: Codable, Equatable, Sendable {
    struct Sample: Codable, Equatable, Sendable { var t: Double; var x: Double; var y: Double }
    var samples: [Sample] = []
    var clicks: [Sample] = []
    /// Recorded area size in points, for the cursor's scale.
    var areaWidth: Double = 0
    var areaHeight: Double = 0

    /// Linear interpolation; the editor smooths on top of this.
    func position(at time: Double) -> CGPoint? {
        guard let first = samples.first else { return nil }
        if time <= first.t { return CGPoint(x: first.x, y: first.y) }
        var low = 0, high = samples.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if samples[mid].t <= time { low = mid } else { high = mid - 1 }
        }
        let a = samples[low]
        guard low + 1 < samples.count else { return CGPoint(x: a.x, y: a.y) }
        let b = samples[low + 1]
        let f = b.t > a.t ? (time - a.t) / (b.t - a.t) : 0
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }
}

/// Click records a whole display, Space then click records a window, dragging records an area.
/// Escape cancels selection. The stop bar is excluded from the video.
@MainActor final class ScreenRecordingController {
    struct Result {
        let url: URL
        let startedAt: Date
        let cursor: CursorTrack
    }

    private enum Phase { case idle, selecting, starting, recording, finishing }
    private var phase = Phase.idle
    var failed: (String) -> Void = { _ in }
    var finished: (Result) -> Void = { _ in }
    var isBusy: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording }

    fileprivate let setup = RecordingSetup()
    private var overlays: [RecordingOverlayWindow] = []
    private var bar: NSView?
    private var keyMonitor: Any?
    private var homeScreen: NSScreen?
    private var pickable: [PickableWindow] = []
    private(set) var selection: RecordingTarget?
    private(set) var windowMode = false
    private(set) var hovered: PickableWindow?
    private(set) var dragRect: CGRect?

    private var recorder: AnyObject?
    private var stopPanel: RecordingStopPanel?
    private var masks: [RecordingMaskWindow] = []
    private var maskTimer: Timer?
    fileprivate var camera: RecordingCameraBubble?
    private var cameraWatch: AnyCancellable?
    private var notice: String?
    private var startedAt = Date()
    private var finishing: Task<Void, Never>?
    private var starting: Task<Void, Never>?
    private var stopAfterStart = false

    private var track = CursorTrack()
    private var trackFrame = CGRect.zero
    private var trackStart: TimeInterval = 0
    private var trackTimer: Timer?
    private var clickMonitors: [Any] = []

    // MARK: Selection

    func start() {
        guard phase == .idle else { return }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            failed(L10n.string("Allow Screen Recording for Nous Browser in System Settings, then try again."))
            return
        }
        phase = .selecting
        setup.reset()
        selection = nil; windowMode = false; hovered = nil; dragRect = nil; notice = nil
        cameraWatch = setup.$camera.dropFirst().removeDuplicates().sink { [weak self] id in
            MainActor.assumeIsolated { self?.cameraChosen(id) }
        }
        homeScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        overlays = NSScreen.screens.map { RecordingOverlayWindow(screen: $0, controller: self) }
        let host = NSHostingView(rootView: RecordingSetupBar(setup: setup) { [weak self] in self?.startRecording() })
        host.setFrameSize(host.fittingSize)
        bar = host
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window is RecordingOverlayWindow else { return event }
            return self.handleKey(event) ? nil : event
        }
        NSApp.activate(ignoringOtherApps: true)
        overlays.forEach { $0.orderFrontRegardless() }
        (overlays.first { $0.targetScreen == homeScreen } ?? overlays.first)?.makeKey()
        refresh()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape: cancel()
        case kVK_Space: toggleWindowMode()
        case kVK_Return, kVK_ANSI_KeypadEnter: startRecording()
        default: return false
        }
        return true
    }

    func cancel() {
        guard phase == .selecting else { return }
        closeOverlays(); phase = .idle
        camera?.close(); camera = nil
    }

    private func closeOverlays() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil; cameraWatch = nil
        bar?.removeFromSuperview(); bar = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
    }

    fileprivate func toggleWindowMode() {
        windowMode.toggle()
        pickable = windowMode ? Self.pickableWindows() : []
        hovered = windowMode ? pickable.first { $0.frame.contains(NSEvent.mouseLocation) } : nil
        refresh()
    }

    /// The rectangle left undimmed on every display.
    var highlight: CGRect? { dragRect ?? (windowMode ? hovered?.frame : selection?.frame) }
    var hint: String? {
        guard dragRect == nil else { return nil }
        if let notice { return notice }
        if windowMode { return hovered == nil ? L10n.string("Click a window to record it · Space for area · Esc to cancel") : nil }
        return selection == nil ? L10n.string("Click to record this screen · Drag to select an area · Space to pick a window · Esc to cancel") : nil
    }

    fileprivate func hover(at point: CGPoint) {
        guard windowMode else { return }
        let next = pickable.first { $0.frame.contains(point) }
        if next != hovered { hovered = next; refresh() }
    }

    fileprivate func drag(from start: CGPoint, to end: CGPoint, on screen: NSScreen) {
        windowMode = false; hovered = nil
        dragRect = ScreenRecordingRules.dragRect(from: start, to: end, within: screen.frame)
        refresh()
    }

    fileprivate func endDrag(on screen: NSScreen) {
        notice = nil
        if let rect = dragRect, ScreenRecordingRules.isUsableArea(rect) {
            selection = RecordingTarget(kind: .area, frame: rect.integral, displayID: screen.recordingDisplayID)
        }
        dragRect = nil; refresh()
    }

    fileprivate func click(at point: CGPoint, on screen: NSScreen) {
        notice = nil
        if windowMode {
            guard let window = pickable.first(where: { $0.frame.contains(point) }) else { return }
            let display = NSScreen.screens.max { $0.frame.intersection(window.frame).area < $1.frame.intersection(window.frame).area } ?? screen
            selection = RecordingTarget(kind: .window(window.id), frame: window.frame.intersection(display.frame), displayID: display.recordingDisplayID)
            windowMode = false; hovered = nil
        } else {
            selection = RecordingTarget(kind: .screen, frame: screen.frame, displayID: screen.recordingDisplayID)
        }
        refresh()
    }

    private func refresh() {
        overlays.forEach { $0.update(hint: hint) }
        camera?.place(in: cameraArea)
        guard let bar else { return }
        let screen = selection.flatMap { target in NSScreen.screens.first { $0.recordingDisplayID == target.displayID } } ?? homeScreen
        guard let screen, let content = overlays.first(where: { $0.targetScreen == screen })?.contentView else { return }
        if bar.superview !== content { bar.removeFromSuperview(); content.addSubview(bar) }
        // Before a selection the bar rests at the bottom; afterwards it sits in the middle of the selection.
        let size = bar.frame.size
        let anchor = selection?.frame ?? CGRect(x: screen.frame.minX, y: screen.visibleFrame.minY + 24, width: screen.frame.width, height: size.height)
        let origin = ScreenRecordingRules.barOrigin(size: size, centeredIn: anchor, screen: screen.frame)
        bar.setFrameOrigin(CGPoint(x: origin.x - screen.frame.minX, y: origin.y - screen.frame.minY))
        bar.isHidden = dragRect != nil || windowMode
    }

    private var cameraArea: CGRect {
        let screen = selection.flatMap { target in NSScreen.screens.first { $0.recordingDisplayID == target.displayID } } ?? homeScreen
        guard let screen else { return .null }
        return (selection?.frame ?? screen.frame).intersection(screen.visibleFrame)
    }

    private func cameraChosen(_ id: String?) {
        guard phase == .selecting else { return }
        guard let id else { camera?.close(); camera = nil; return }
        Task {
            let allowed = await Self.access(.video)
            guard phase == .selecting, setup.camera == id else { return }
            guard allowed else {
                setup.camera = nil
                notice = L10n.string("Allow Camera for Nous Browser in System Settings › Privacy & Security › Camera")
                refresh(); return
            }
            let bubble = camera ?? RecordingCameraBubble()
            guard bubble.use(id) else {
                setup.camera = nil; notice = L10n.string("That camera is unavailable. Choose another one.")
                refresh(); return
            }
            if camera == nil { camera = bubble; bubble.place(in: cameraArea); bubble.show() }
            NSApp.activate(ignoringOtherApps: true)
            overlays.first { $0.targetScreen == homeScreen }?.makeKey()
        }
    }

    static func pickableWindows() -> [PickableWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let own = ProcessInfo.processInfo.processIdentifier
        // Front-to-back order, so the first hit is the visible window. Nous's own
        // windows can be recorded too; only its overlays are skipped.
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width >= 40, rect.height >= 40 else { return nil }
            if (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == own,
               (info[kCGWindowName as String] as? String)?.hasPrefix("Nous Recording") == true { return nil }
            return PickableWindow(id: CGWindowID(id), frame: ScreenRecordingRules.appKitRect(windowBounds: rect, primaryHeight: primary))
        }
    }

    // MARK: Recording

    private func startRecording() {
        guard phase == .selecting, let screen = homeScreen ?? NSScreen.main else { return }
        let target = selection ?? RecordingTarget(kind: .screen, frame: screen.frame, displayID: screen.recordingDisplayID)
        let microphone = setup.microphone, cameraID = setup.camera, systemAudio = setup.systemAudio
        closeOverlays()
        phase = .starting
        stopAfterStart = false
        starting = Task {
            await launch(target, microphone: microphone, cameraID: cameraID, systemAudio: systemAudio)
            starting = nil
        }
    }

    private func launch(_ target: RecordingTarget, microphone: String?, cameraID: String?, systemAudio: Bool) async {
        do {
            try Task.checkCancellation()
            if microphone != nil, !(await Self.access(.audio)) {
                throw RecordingFailure(message: L10n.string("Allow Microphone for Nous Browser in System Settings, or record with the microphone off."))
            }
            try Task.checkCancellation()
            if cameraID != nil, camera == nil {
                throw RecordingFailure(message: L10n.string("The camera preview could not start. Allow Camera for Nous Browser in System Settings, or record with the camera off."))
            }
            guard let screen = NSScreen.screens.first(where: { $0.recordingDisplayID == target.displayID }) else {
                throw RecordingFailure(message: L10n.string("The selected display is no longer connected."))
            }
            let panel = RecordingStopPanel()
            panel.model.stop = { [weak self] in self?.stop() }
            panel.show(on: screen)
            stopPanel = panel
            showMasks(for: target)
            // Let the window server publish both windows so ScreenCaptureKit can exclude or include them.
            try await Task.sleep(nanoseconds: 150_000_000)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
                throw RecordingFailure(message: L10n.string("The selected display is unavailable for recording."))
            }
            func shareable(_ window: NSWindow?) -> SCWindow? {
                guard let window else { return nil }
                return content.windows.first { $0.windowID == CGWindowID(window.windowNumber) }
            }
            let filter: SCContentFilter
            if case .window(let id) = target.kind {
                guard let window = content.windows.first(where: { $0.windowID == id }) else {
                    throw RecordingFailure(message: L10n.string("The selected window closed before recording started."))
                }
                filter = SCContentFilter(display: display, including: [window] + [shareable(camera?.window)].compactMap { $0 })
            } else {
                filter = SCContentFilter(display: display,
                                         excludingWindows: ([panel] + masks).compactMap { shareable($0) })
            }
            let config = SCStreamConfiguration()
            let source = ScreenRecordingRules.sourceRect(target.frame, screenFrame: screen.frame)
            config.sourceRect = source
            config.width = ScreenRecordingRules.pixels(source.width, scale: screen.backingScaleFactor)
            config.height = ScreenRecordingRules.pixels(source.height, scale: screen.backingScaleFactor)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            // The editor draws a smoothed pointer from the recorded track instead.
            config.showsCursor = false
            config.capturesAudio = systemAudio
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000; config.channelCount = 2
            config.captureMicrophone = microphone != nil
            config.microphoneCaptureDeviceID = microphone
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("NousRecording-\(UUID().uuidString).mp4")
            let recorder = ScreenRecorder(url: url)
            recorder.interrupted = { [weak self] in self?.stop() }
            self.recorder = recorder
            try await recorder.start(filter: filter, configuration: config)
            startedAt = Date()
            startTrack(frame: target.frame.intersection(screen.frame))
            phase = .recording
            panel.model.state = .recording(startedAt)
            if stopAfterStart || Task.isCancelled || recorder.hasRequestedStop { stop() }
        } catch {
            if let recorder = recorder as? ScreenRecorder { _ = await recorder.stop() }
            tearDownRecording()
            phase = .idle
            guard !(error is CancellationError) else { return }
            failed(error is RecordingFailure ? error.localizedDescription
                   : L10n.string("Could not start screen recording:") + " " + error.localizedDescription)
        }
    }

    private func startTrack(frame: CGRect) {
        track = CursorTrack(areaWidth: frame.width, areaHeight: frame.height)
        trackFrame = frame
        trackStart = ProcessInfo.processInfo.systemUptime
        sampleCursor()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleCursor() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackTimer = timer
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.recordClick() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in
            handler(event)
            return event
        }) { clickMonitors.append(local) }
    }

    private func normalizedPointer() -> CursorTrack.Sample? {
        guard trackFrame.width > 0, trackFrame.height > 0 else { return nil }
        let point = NSEvent.mouseLocation
        return .init(t: ProcessInfo.processInfo.systemUptime - trackStart,
                     x: (point.x - trackFrame.minX) / trackFrame.width,
                     y: (trackFrame.maxY - point.y) / trackFrame.height)
    }

    private func sampleCursor() {
        guard let sample = normalizedPointer() else { return }
        if let last = track.samples.last, abs(last.x - sample.x) < 0.0001, abs(last.y - sample.y) < 0.0001,
           sample.t - last.t < 0.5 { return }
        track.samples.append(sample)
    }

    private func recordClick() {
        guard phase == .recording, let sample = normalizedPointer() else { return }
        track.clicks.append(sample)
    }

    private func stopTrack() {
        trackTimer?.invalidate(); trackTimer = nil
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
    }

    func stop() {
        if phase == .starting { stopAfterStart = true; return }
        guard phase == .recording, let recorder = recorder as? ScreenRecorder else { return }
        phase = .finishing
        hideMasks()
        stopTrack()
        stopPanel?.model.state = .saving
        let track = self.track
        finishing = Task {
            let error = await recorder.stop()
            self.recorder = nil
            camera?.close(); camera = nil
            let size = (try? FileManager.default.attributesOfItem(atPath: recorder.url.path)[.size] as? NSNumber)?.intValue ?? 0
            if let error {
                failed(L10n.string("The recording did not finish cleanly:") + " " + error.localizedDescription)
            } else if size == 0 {
                try? FileManager.default.removeItem(at: recorder.url)
                failed(L10n.string("The recording could not be finished."))
            } else {
                stopPanel?.model.state = .saved
                finished(Result(url: recorder.url, startedAt: startedAt, cursor: track))
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            tearDownRecording()
            phase = .idle
            finishing = nil
        }
    }

    /// Quitting mid-recording still saves what was captured.
    func finishBeforeQuit() async {
        if phase == .selecting { cancel() }
        if phase == .starting {
            stopAfterStart = true
            starting?.cancel()
            await starting?.value
        }
        if phase == .recording { stop() }
        await finishing?.value
    }

    /// Dims everything outside the recorded area on every display, so it is
    /// always clear what is being captured. Click-through, never recorded.
    private func showMasks(for target: RecordingTarget) {
        masks = NSScreen.screens.map { RecordingMaskWindow(screen: $0) }
        masks.forEach { $0.update(hole: target.frame) }
        masks.forEach { $0.reveal() }
        guard case .window(let id) = target.kind else { return }
        // Follow the recorded window if it moves or resizes.
        maskTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let frame = Self.pickableWindows().first(where: { $0.id == id })?.frame else { return }
                self.masks.forEach { $0.update(hole: frame) }
            }
        }
    }

    private func hideMasks() {
        maskTimer?.invalidate(); maskTimer = nil
        masks.forEach { $0.dismiss() }
        masks = []
    }

    private func tearDownRecording() {
        hideMasks()
        stopTrack()
        camera?.close(); camera = nil
        stopPanel?.orderOut(nil); stopPanel = nil
        recorder = nil
    }

    private static func access(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

// MARK: Overlay

/// A click-through dimming layer with a hole over the recorded area.
final class RecordingMaskWindow: NSWindow {
    private let targetScreen: NSScreen
    private let shape = CAShapeLayer()
    private let edge = CAShapeLayer()

    init(screen: NSScreen) {
        targetScreen = screen
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        ignoresMouseEvents = true
        // Above apps and the menu bar, below the stop bar and camera bubble.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false; animationBehavior = .none
        title = "Nous Recording Mask"
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        shape.fillRule = .evenOdd
        shape.fillColor = NSColor.black.withAlphaComponent(0.42).cgColor
        edge.fillColor = nil
        edge.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        edge.lineWidth = 1
        view.layer?.addSublayer(shape)
        view.layer?.addSublayer(edge)
        contentView = view
        alphaValue = 0
    }

    func update(hole: CGRect) {
        let bounds = CGRect(origin: .zero, size: targetScreen.frame.size)
        let local = hole.intersection(targetScreen.frame).offsetBy(dx: -targetScreen.frame.minX, dy: -targetScreen.frame.minY)
        let path = CGMutablePath()
        path.addRect(bounds)
        // A whole-display recording leaves its own display undimmed.
        let visible = !local.isNull && !local.isEmpty
        if visible { path.addRect(local) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.path = path
        let covered = visible && local.insetBy(dx: 1, dy: 1).contains(bounds.insetBy(dx: 2, dy: 2))
        edge.path = visible && !covered ? CGPath(rect: local.insetBy(dx: -0.5, dy: -0.5), transform: nil) : nil
        CATransaction.commit()
    }

    func reveal() {
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.orderOut(nil) }
        })
    }
}

final class RecordingOverlayWindow: NSWindow {
    let targetScreen: NSScreen
    private let overlay: RecordingOverlayView
    private let hintHost = PassthroughHostingView(rootView: RecordingHint(text: ""))
    init(screen: NSScreen, controller: ScreenRecordingController) {
        targetScreen = screen
        overlay = RecordingOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen, controller: controller)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        // Above the menu bar and Dock, below the pop-up menus the setup bar opens.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false; animationBehavior = .none; acceptsMouseMovedEvents = true
        title = "Nous Recording Selection"
        contentView = overlay
        overlay.addSubview(hintHost)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    func update(hint: String?) {
        overlay.needsDisplay = true
        hintHost.isHidden = hint == nil
        guard let hint else { return }
        hintHost.rootView = RecordingHint(text: hint)
        let size = hintHost.fittingSize
        hintHost.frame = NSRect(x: ((overlay.bounds.width - size.width) / 2).rounded(), y: ((overlay.bounds.height - size.height) / 2).rounded(),
                                width: size.width, height: size.height)
    }
}

private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class RecordingOverlayView: NSView {
    private let screen: NSScreen
    private weak var controller: ScreenRecordingController?
    private var pressed: CGPoint?
    private var dragging = false
    init(frame: NSRect, screen: NSScreen, controller: ScreenRecordingController) {
        self.screen = screen; self.controller = controller
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseMoved(with event: NSEvent) { controller?.hover(at: NSEvent.mouseLocation) }
    override func mouseDown(with event: NSEvent) {
        pressed = NSEvent.mouseLocation; dragging = false
        if window?.isKeyWindow == false { window?.makeKey() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let pressed else { return }
        let point = NSEvent.mouseLocation
        if dragging || ScreenRecordingRules.isDrag(from: pressed, to: point) {
            dragging = true
            controller?.drag(from: pressed, to: point, on: screen)
        }
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; dragging = false }
        guard pressed != nil else { return }
        if dragging { controller?.endDrag(on: screen) } else { controller?.click(at: NSEvent.mouseLocation, on: screen) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let controller else { return }
        let local = controller.highlight.map { $0.intersection(screen.frame) }
            .flatMap { $0.isNull || $0.isEmpty ? nil : $0.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
        let dim = NSBezierPath(rect: bounds)
        if let local { dim.append(NSBezierPath(rect: local)); dim.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.3).setFill()
        dim.fill()
        guard let local else { return }
        if controller.windowMode {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(rect: local).fill()
        }
        let border = NSBezierPath(rect: local.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        border.stroke()
        if controller.dragRect != nil {
            let scale = screen.backingScaleFactor
            let label = "\(Int(local.width * scale)) × \(Int(local.height * scale))" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
            let size = label.size(withAttributes: attributes)
            let below = local.minY - size.height - 8 > 0
            let box = NSRect(x: local.minX, y: below ? local.minY - size.height - 10 : local.minY + 6, width: size.width + 12, height: size.height + 4)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
            label.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 2), withAttributes: attributes)
        }
    }
}
