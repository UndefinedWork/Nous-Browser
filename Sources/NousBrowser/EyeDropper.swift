import AppKit
import CoreGraphics
import NousCore
import Observation
import ScreenCaptureKit
import SwiftUI

// MARK: - Pure Color & Pixel Sampling Models

/// An sRGB color sampled by the EyeDropper.
nonisolated struct EyeDropperColor: Equatable, Hashable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    var rgbString: String {
        "\(red), \(green), \(blue)"
    }

    var swiftUIColor: Color {
        Color(.sRGB, red: Double(red) / 255.0, green: Double(green) / 255.0, blue: Double(blue) / 255.0)
    }

    /// Relative sRGB luminance used to pick a high-contrast crosshair color.
    var isLight: Bool {
        let r = Double(red) / 255.0
        let g = Double(green) / 255.0
        let b = Double(blue) / 255.0
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) > 0.56
    }
}

/// A sampled square pixel neighborhood centered on the cursor's target pixel.
nonisolated struct EyeDropperSample: Equatable, Sendable {
    let center: EyeDropperColor
    let gridSize: Int
    /// Row-major (top-to-bottom, left-to-right), length `gridSize * gridSize`.
    let pixels: [EyeDropperColor?]
}

/// An sRGB RGBA8 bitmap covering a rectangle in AppKit global screen coordinates.
nonisolated struct EyeDropperSurface: Sendable {
    let screenRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let bytesPerRow: Int
    let pixels: Data

    init(screenRect: CGRect, pixelWidth: Int, pixelHeight: Int, bytesPerRow: Int, pixels: Data) {
        self.screenRect = screenRect
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
    }

    /// Decodes any CGImage (Display P3, sRGB, etc.) into an sRGB RGBX8 buffer so
    /// every pixel lookup is O(1) and matches the W3C EyeDropper sRGB spec.
    init?(cgImage: CGImage, screenRect: CGRect) {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0, screenRect.width > 0, screenRect.height > 0,
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: sRGB,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(screenRect: screenRect, pixelWidth: width, pixelHeight: height, bytesPerRow: bytesPerRow, pixels: data)
    }

    /// Maps an AppKit global screen point (bottom-left origin, Y up) to a
    /// top-left-origin pixel coordinate inside this surface.
    func pixelCoordinate(for screenPoint: CGPoint) -> (x: Int, y: Int)? {
        guard screenPoint.x >= screenRect.minX, screenPoint.x <= screenRect.maxX,
              screenPoint.y >= screenRect.minY, screenPoint.y <= screenRect.maxY,
              screenRect.width > 0, screenRect.height > 0 else { return nil }
        let normalizedX = (screenPoint.x - screenRect.minX) / screenRect.width
        let normalizedY = (screenRect.maxY - screenPoint.y) / screenRect.height
        let x = min(max(0, Int(floor(normalizedX * Double(pixelWidth)))), pixelWidth - 1)
        let y = min(max(0, Int(floor(normalizedY * Double(pixelHeight)))), pixelHeight - 1)
        return (x, y)
    }

    func color(atPixelX x: Int, y: Int) -> EyeDropperColor? {
        guard x >= 0, x < pixelWidth, y >= 0, y < pixelHeight else { return nil }
        let offset = y * bytesPerRow + x * 4
        guard offset + 2 < pixels.count else { return nil }
        return EyeDropperColor(red: pixels[offset], green: pixels[offset + 1], blue: pixels[offset + 2])
    }

    func sample(at screenPoint: CGPoint, gridSize: Int, fallbackSurfaces: [EyeDropperSurface] = []) -> EyeDropperSample? {
        guard let (centerX, centerY) = pixelCoordinate(for: screenPoint),
              let centerColor = color(atPixelX: centerX, y: centerY) else { return nil }
        let oddGrid = max(3, gridSize | 1)
        let radius = oddGrid / 2
        let pointsPerPixelX = screenRect.width / CGFloat(pixelWidth)
        let pointsPerPixelY = screenRect.height / CGFloat(pixelHeight)

        var cells: [EyeDropperColor?] = []
        cells.reserveCapacity(oddGrid * oddGrid)
        for dy in -radius...radius {
            let py = centerY + dy
            for dx in -radius...radius {
                let px = centerX + dx
                if let direct = color(atPixelX: px, y: py) {
                    cells.append(direct)
                } else if !fallbackSurfaces.isEmpty {
                    let neighborPoint = CGPoint(
                        x: screenPoint.x + CGFloat(dx) * pointsPerPixelX,
                        y: screenPoint.y - CGFloat(dy) * pointsPerPixelY
                    )
                    let fallback = fallbackSurfaces.lazy.compactMap { surface -> EyeDropperColor? in
                        guard let coord = surface.pixelCoordinate(for: neighborPoint) else { return nil }
                        return surface.color(atPixelX: coord.x, y: coord.y)
                    }.first
                    cells.append(fallback)
                } else {
                    cells.append(nil)
                }
            }
        }
        return EyeDropperSample(center: centerColor, gridSize: oddGrid, pixels: cells)
    }
}

// MARK: - Loupe Geometry

/// Computes the floating loupe panel frame so the circular lens stays locked
/// 1:1 onto the cursor while the Liquid Glass readout pill flips/clamps cleanly
/// near screen edges.
nonisolated enum EyeDropperLoupeLayout {
    enum PillPlacement: Equatable, Sendable { case below, above }

    struct Result: Equatable, Sendable {
        let panelOrigin: CGPoint
        let panelSize: CGSize
        let pillPlacement: PillPlacement
        let pillOffsetX: CGFloat
    }

    static let lensDiameter: CGFloat = 136
    static let pillGap: CGFloat = 10
    static let pillHeight: CGFloat = 34
    static let pillWidth: CGFloat = 180
    static let shadowMargin: CGFloat = 20
    static let edgeInset: CGFloat = 10
    static let maxPillHorizontalShift: CGFloat = 48

    /// Symmetric panel dimensions with the circular lens centered at
    /// `(panelSize.width / 2, panelSize.height / 2)`, so flipping the pill
    /// never shifts or jitters the lens position.
    static let panelSize = CGSize(
        width: pillWidth + maxPillHorizontalShift * 2 + shadowMargin * 2,
        height: lensDiameter + (pillGap + pillHeight) * 2 + shadowMargin * 2
    )

    static let zoomLevels: [Int] = [7, 9, 11, 13, 15, 19]
    static let defaultGridSize: Int = 11

    static func nextZoomLevel(from current: Int, zoomIn: Bool) -> Int {
        let index = zoomLevels.firstIndex(of: current) ?? zoomLevels.firstIndex(of: defaultGridSize) ?? 2
        let next = zoomIn ? max(0, index - 1) : min(zoomLevels.count - 1, index + 1)
        return zoomLevels[next]
    }

    static func compute(cursor: CGPoint, screenFrame: CGRect) -> Result {
        let origin = CGPoint(
            x: round(cursor.x - panelSize.width / 2),
            y: round(cursor.y - panelSize.height / 2)
        )
        let neededBelow = lensDiameter / 2 + pillGap + pillHeight + edgeInset
        let placement: PillPlacement = (cursor.y - neededBelow < screenFrame.minY) ? .above : .below

        let halfPill = pillWidth / 2
        let minCenterX = screenFrame.minX + edgeInset + halfPill
        let maxCenterX = screenFrame.maxX - edgeInset - halfPill
        var shiftX: CGFloat = 0
        if minCenterX <= maxCenterX {
            if cursor.x < minCenterX {
                shiftX = min(maxPillHorizontalShift, minCenterX - cursor.x)
            } else if cursor.x > maxCenterX {
                shiftX = max(-maxPillHorizontalShift, maxCenterX - cursor.x)
            }
        }
        return Result(panelOrigin: origin, panelSize: panelSize, pillPlacement: placement, pillOffsetX: shiftX)
    }
}

// MARK: - Coordinator

/// Connects Chromium's NBEyeDropperCenter to Nous's native Liquid Glass loupe.
@MainActor
final class EyeDropperCoordinator {
    static let shared = EyeDropperCoordinator()

    private var activePicker: EyeDropperPicker?

    func start() {
        NBEyeDropperCenter.shared().sessionHandler = { [weak self] session in
            MainActor.assumeIsolated {
                self?.present(session: session)
            }
        }
    }

    func cancelIfActive() {
        activePicker?.cancel(notifyEngine: true)
        activePicker = nil
    }

    private func present(session: NBEyeDropperSession) {
        activePicker?.cancel(notifyEngine: true)
        let picker = EyeDropperPicker(session: session) { [weak self] finished in
            if self?.activePicker === finished {
                self?.activePicker = nil
            }
        }
        activePicker = picker
        picker.start()
    }
}

// MARK: - Active Picker Session

@MainActor
@Observable
private final class EyeDropperLoupeState {
    var sample: EyeDropperSample?
    var gridSize: Int = EyeDropperLoupeLayout.defaultGridSize
    var pillPlacement: EyeDropperLoupeLayout.PillPlacement = .below
    var pillOffsetX: CGFloat = 0
    var isReady = false
    var isPageOnlyScope = false
    var isPresented = false
}

@MainActor
private final class EyeDropperPicker {
    private let session: NBEyeDropperSession
    private let onFinished: (EyeDropperPicker) -> Void
    private let state = EyeDropperLoupeState()

    private var surfaces: [EyeDropperSurface] = []
    private var catcherPanels: [EyeDropperCatcherPanel] = []
    private var loupePanel: EyeDropperLoupePanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var syncTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var captureTask: Task<Void, Never>?

    private var lastHardwareCursor: CGPoint = NSEvent.mouseLocation
    private var effectiveCursor: CGPoint = NSEvent.mouseLocation
    private var scrollAccumulator: CGFloat = 0
    private var isClosed = false

    init(session: NBEyeDropperSession, onFinished: @escaping (EyeDropperPicker) -> Void) {
        self.session = session
        self.onFinished = onFinished
    }

    func start() {
        guard !session.isFinished else {
            onFinished(self)
            return
        }
        session.cancelHandler = { [weak self] in
            MainActor.assumeIsolated {
                self?.cancel(notifyEngine: false)
            }
        }

        let initialPoint = NSEvent.mouseLocation
        lastHardwareCursor = initialPoint
        effectiveCursor = initialPoint

        // Capture first while no overlay windows exist so ScreenCaptureKit never
        // captures our own loupe, then mount the catcher + loupe immediately.
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let captured = await self.captureSurfaces()
            guard !self.isClosed, !self.session.isFinished else { return }
            guard !captured.surfaces.isEmpty else {
                self.cancel(notifyEngine: true)
                return
            }
            self.surfaces = captured.surfaces
            self.state.isPageOnlyScope = captured.isPageOnly
            self.state.isReady = true
            self.mountOverlay()
            self.updatePosition(NSEvent.mouseLocation, resetNudge: true)
            self.state.isPresented = true
        }
    }

    func confirm() {
        guard !isClosed else { return }
        guard let color = state.sample?.center else {
            cancel(notifyEngine: true)
            return
        }
        let targetSession = session
        let sourceWindow = session.sourceWindow
        teardown()
        targetSession.selectRed(color.red, green: color.green, blue: color.blue)
        restoreSourceWindow(sourceWindow)
        onFinished(self)
    }

    func cancel(notifyEngine: Bool) {
        guard !isClosed else { return }
        let targetSession = session
        let sourceWindow = session.sourceWindow
        teardown()
        if notifyEngine {
            targetSession.cancel()
        }
        restoreSourceWindow(sourceWindow)
        onFinished(self)
    }

    private func restoreSourceWindow(_ window: NSWindow?) {
        guard let window, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Surface Capture

    private struct CaptureResult {
        let surfaces: [EyeDropperSurface]
        let isPageOnly: Bool
    }

    private func captureSurfaces() async -> CaptureResult {
        // When Screen Recording is already authorized, capture all connected
        // displays at full Retina resolution in sRGB so the user can sample
        // anywhere on screen (webpage, sidebar, other apps, desktop).
        if CGPreflightScreenCaptureAccess() {
            // Give an invoking <input type="color"> popup one frame to dismiss
            // so the screen snapshot does not capture the closing popup itself.
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled, !isClosed, !session.isFinished else {
                return CaptureResult(surfaces: [], isPageOnly: false)
            }
            let screenSurfaces = await captureAllDisplaysWithScreenCaptureKit()
            if !screenSurfaces.isEmpty {
                return CaptureResult(surfaces: screenSurfaces, isPageOnly: false)
            }
        }
        // Without Screen Recording permission (or if SCK fails), capture the
        // requesting webpage directly from Chromium's GPU compositor with zero
        // OS permission prompts.
        if let pageSurface = await captureWebpageSurface() {
            return CaptureResult(surfaces: [pageSurface], isPageOnly: true)
        }
        return CaptureResult(surfaces: [], isPageOnly: true)
    }

    private func captureAllDisplaysWithScreenCaptureKit() async -> [EyeDropperSurface] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let screensByID: [CGDirectDisplayID: NSScreen] = Dictionary(
                uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                        return nil
                    }
                    return (CGDirectDisplayID(number.uint32Value), screen)
                }
            )

            var rawCaptures: [(CGImage, CGRect)] = []
            for display in content.displays {
                guard let screen = screensByID[display.displayID] else { continue }
                let scale = max(1.0, screen.backingScaleFactor)
                let config = SCStreamConfiguration()
                config.width = max(1, Int(round(screen.frame.width * scale)))
                config.height = max(1, Int(round(screen.frame.height * scale)))
                config.showsCursor = false
                config.scalesToFit = false
                config.colorSpaceName = CGColorSpace.sRGB
                config.pixelFormat = kCVPixelFormatType_32BGRA

                let filter = SCContentFilter(display: display, excludingWindows: [])
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    rawCaptures.append((image, screen.frame))
                }
            }
            guard !rawCaptures.isEmpty else { return [] }
            return await Task.detached(priority: .userInitiated) {
                rawCaptures.compactMap { EyeDropperSurface(cgImage: $0.0, screenRect: $0.1) }
            }.value
        } catch {
            return []
        }
    }

    private func captureWebpageSurface() async -> EyeDropperSurface? {
        let snapshot: (CGImage, CGRect)? = await withCheckedContinuation { continuation in
            session.capturePageSnapshot { bitmap, screenRect in
                guard let cgImage = bitmap?.cgImage, !screenRect.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (cgImage, screenRect))
            }
        }
        guard let (cgImage, screenRect) = snapshot else { return nil }
        return await Task.detached(priority: .userInitiated) {
            EyeDropperSurface(cgImage: cgImage, screenRect: screenRect)
        }.value
    }

    // MARK: - Overlay Windows & Event Routing

    private func mountOverlay() {
        let screens = NSScreen.screens
        let cursor = NSEvent.mouseLocation

        // 1. One transparent full-screen catcher panel per display intercepts
        // clicks, scroll zoom, keyboard shortcuts, and sets an invisible cursor.
        for screen in screens {
            let panel = EyeDropperCatcherPanel(screen: screen)
            let catcher = EyeDropperCatcherView(frame: CGRect(origin: .zero, size: screen.frame.size))
            catcher.onMouseMove = { [weak self] point in self?.updatePosition(point, resetNudge: true) }
            catcher.onConfirm = { [weak self] in self?.confirm() }
            catcher.onCancel = { [weak self] in self?.cancel(notifyEngine: true) }
            catcher.onScroll = { [weak self] deltaY in self?.handleScroll(deltaY) }
            catcher.onKeyDown = { [weak self] event in self?.handleKeyDown(event) ?? false }
            panel.contentView = catcher
            panel.orderFrontRegardless()
            catcherPanels.append(panel)
        }

        // Make the catcher on the cursor's display key so keyboard events work immediately.
        let keyCatcher = catcherPanels.first { $0.frame.contains(cursor) } ?? catcherPanels.first
        keyCatcher?.makeKeyAndOrderFront(nil)
        if let contentView = keyCatcher?.contentView {
            keyCatcher?.makeFirstResponder(contentView)
        }

        // 2. One floating Liquid Glass loupe panel rendered above the catchers.
        let loupe = EyeDropperLoupePanel(size: EyeDropperLoupeLayout.panelSize)
        let host = NSHostingView(rootView: EyeDropperLoupeView(state: state))
        host.frame = CGRect(origin: .zero, size: EyeDropperLoupeLayout.panelSize)
        loupe.contentView = host
        loupe.orderFrontRegardless()
        loupePanel = loupe

        // 3. Belt-and-suspenders event monitors + 60Hz position sync so tracking
        // never stalls across monitor seams, menu bar, or rapid pointer motion.
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, !self.isClosed else { return event }
            switch event.type {
            case .mouseMoved, .leftMouseDragged:
                self.updatePosition(NSEvent.mouseLocation, resetNudge: true)
                return event
            case .rightMouseDown:
                self.cancel(notifyEngine: true)
                return nil
            case .keyDown:
                return self.handleKeyDown(event) ? nil : event
            default:
                return event
            }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                if event.type == .rightMouseDown {
                    self.cancel(notifyEngine: true)
                } else {
                    self.updatePosition(NSEvent.mouseLocation, resetNudge: true)
                }
            }
        }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                let now = NSEvent.mouseLocation
                if now != self.lastHardwareCursor {
                    self.updatePosition(now, resetNudge: true)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel(notifyEngine: true) }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel(notifyEngine: true) }
        })
    }

    private func updatePosition(_ point: CGPoint, resetNudge: Bool) {
        guard !isClosed else { return }
        if resetNudge {
            lastHardwareCursor = point
            effectiveCursor = point
        } else {
            effectiveCursor = point
        }
        let target = effectiveCursor
        let screen = NSScreen.screens.first { $0.frame.contains(target) } ?? NSScreen.main
        let screenFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let layout = EyeDropperLoupeLayout.compute(cursor: target, screenFrame: screenFrame)
        loupePanel?.setFrameOrigin(layout.panelOrigin)
        if state.pillPlacement != layout.pillPlacement {
            state.pillPlacement = layout.pillPlacement
        }
        if abs(state.pillOffsetX - layout.pillOffsetX) > 0.25 {
            state.pillOffsetX = layout.pillOffsetX
        }
        refreshSample(at: target)
    }

    private func refreshSample(at point: CGPoint) {
        if let primary = surfaces.first(where: { $0.pixelCoordinate(for: point) != nil }) {
            let siblings = surfaces.count > 1 ? surfaces.filter { $0.screenRect != primary.screenRect } : []
            state.sample = primary.sample(at: point, gridSize: state.gridSize, fallbackSurfaces: siblings)
        } else {
            state.sample = nil
        }
    }

    private func handleScroll(_ deltaY: CGFloat) {
        scrollAccumulator += deltaY
        let threshold: CGFloat = 1.5
        guard abs(scrollAccumulator) >= threshold else { return }
        let zoomIn = scrollAccumulator > 0
        scrollAccumulator = 0
        let next = EyeDropperLoupeLayout.nextZoomLevel(from: state.gridSize, zoomIn: zoomIn)
        guard next != state.gridSize else { return }
        state.gridSize = next
        refreshSample(at: effectiveCursor)
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 53: // Escape
            cancel(notifyEngine: true)
            return true
        case 36, 76, 49: // Return, Enter, Space
            confirm()
            return true
        case 123: // Left
            updatePosition(CGPoint(x: effectiveCursor.x - step, y: effectiveCursor.y), resetNudge: false)
            return true
        case 124: // Right
            updatePosition(CGPoint(x: effectiveCursor.x + step, y: effectiveCursor.y), resetNudge: false)
            return true
        case 125: // Down (AppKit Y decreases downward)
            updatePosition(CGPoint(x: effectiveCursor.x, y: effectiveCursor.y - step), resetNudge: false)
            return true
        case 126: // Up
            updatePosition(CGPoint(x: effectiveCursor.x, y: effectiveCursor.y + step), resetNudge: false)
            return true
        default:
            if let chars = event.charactersIgnoringModifiers {
                if chars == "+" || chars == "=" {
                    state.gridSize = EyeDropperLoupeLayout.nextZoomLevel(from: state.gridSize, zoomIn: true)
                    refreshSample(at: effectiveCursor)
                    return true
                }
                if chars == "-" || chars == "_" {
                    state.gridSize = EyeDropperLoupeLayout.nextZoomLevel(from: state.gridSize, zoomIn: false)
                    refreshSample(at: effectiveCursor)
                    return true
                }
            }
            return false
        }
    }

    private func teardown() {
        guard !isClosed else { return }
        isClosed = true
        session.cancelHandler = nil
        captureTask?.cancel()
        captureTask = nil
        syncTimer?.invalidate()
        syncTimer = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()

        loupePanel?.orderOut(nil)
        loupePanel?.close()
        loupePanel = nil

        for panel in catcherPanels {
            panel.orderOut(nil)
            panel.close()
        }
        catcherPanels.removeAll()
        surfaces.removeAll()
    }
}

// MARK: - AppKit Overlay Panels

private final class EyeDropperCatcherPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) - 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class EyeDropperLoupePanel: NSPanel {
    init(size: CGSize) {
        super.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class EyeDropperCatcherView: NSView {
    var onMouseMove: ((CGPoint) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?

    private var tracking: NSTrackingArea?

    /// A 1x1 transparent cursor disappears automatically when this panel closes,
    /// avoiding unbalanced NSCursor.hide() state.
    private static let invisibleCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }()

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: Self.invisibleCursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        Self.invisibleCursor.set()
    }

    override func mouseEntered(with event: NSEvent) {
        Self.invisibleCursor.set()
        onMouseMove?(NSEvent.mouseLocation)
    }

    override func mouseMoved(with event: NSEvent) {
        Self.invisibleCursor.set()
        onMouseMove?(NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseMove?(NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        onConfirm?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Liquid Glass Loupe UI

private struct EyeDropperLoupeView: View {
    let state: EyeDropperLoupeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lensDiameter: CGFloat { EyeDropperLoupeLayout.lensDiameter }
    private var pillYOffset: CGFloat {
        let distance = lensDiameter / 2 + EyeDropperLoupeLayout.pillGap + EyeDropperLoupeLayout.pillHeight / 2
        return state.pillPlacement == .below ? distance : -distance
    }

    var body: some View {
        ZStack {
            lens
                .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)

            readoutPill
                .offset(x: state.pillOffsetX, y: pillYOffset)
                .animation(reduceMotion ? nil : BrowserMotion.interaction, value: state.pillPlacement)
        }
        .frame(width: EyeDropperLoupeLayout.panelSize.width, height: EyeDropperLoupeLayout.panelSize.height)
        .scaleEffect(state.isPresented ? 1.0 : 0.88)
        .opacity(state.isPresented ? 1.0 : 0.0)
        .animation(reduceMotion ? nil : BrowserMotion.interaction, value: state.isPresented)
    }

    @ViewBuilder
    private var lens: some View {
        let activeColor = state.sample?.center
        ZStack {
            if let sample = state.sample {
                EyeDropperPixelGridCanvas(sample: sample)
                    .frame(width: lensDiameter, height: lensDiameter)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: lensDiameter, height: lensDiameter)
                    .overlay {
                        Image(systemName: "eyedropper")
                            .font(.system(size: 26, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
            }

            // Live sampled-color inner rim for immediate peripheral feedback.
            Circle()
                .strokeBorder(
                    activeColor?.swiftUIColor ?? Color.primary.opacity(0.18),
                    lineWidth: 3.5
                )
                .frame(width: lensDiameter, height: lensDiameter)

            // Outer Liquid Glass specular bezel.
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.85),
                            Color.white.opacity(0.28),
                            Color.black.opacity(0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
                .frame(width: lensDiameter + 2, height: lensDiameter + 2)

            Circle()
                .strokeBorder(Color.black.opacity(0.22), lineWidth: 0.5)
                .frame(width: lensDiameter + 3, height: lensDiameter + 3)
        }
    }

    @ViewBuilder
    private var readoutPill: some View {
        HStack(spacing: 7) {
            if let color = state.sample?.center {
                Circle()
                    .fill(color.swiftUIColor)
                    .frame(width: 14, height: 14)
                    .overlay {
                        Circle()
                            .strokeBorder(
                                (color.isLight ? Color.black : Color.white).opacity(0.24),
                                lineWidth: 0.75
                            )
                    }
                Text(color.hexString)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                Rectangle()
                    .fill(Color.primary.opacity(0.16))
                    .frame(width: 1, height: 11)
                Text(color.rgbString)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "eyedropper")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(L10n.string(state.isPageOnlyScope ? "Move over webpage" : "Pick Color"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .padding(.horizontal, 12)
        .frame(height: EyeDropperLoupeLayout.pillHeight)
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

private struct EyeDropperPixelGridCanvas: View {
    let sample: EyeDropperSample

    var body: some View {
        Canvas(opaque: true, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
            let grid = sample.gridSize
            guard grid > 0 else { return }
            let cellW = size.width / CGFloat(grid)
            let cellH = size.height / CGFloat(grid)

            // 1. Draw crisp nearest-neighbor pixel cells.
            for row in 0..<grid {
                let y = CGFloat(row) * cellH
                for col in 0..<grid {
                    let index = row * grid + col
                    let rect = CGRect(x: CGFloat(col) * cellW, y: y, width: cellW + 0.35, height: cellH + 0.35)
                    if index < sample.pixels.count, let pixel = sample.pixels[index] {
                        context.fill(Path(rect), with: .color(pixel.swiftUIColor))
                    } else {
                        let checker = (row + col).isMultiple(of: 2) ? 0.14 : 0.22
                        context.fill(Path(rect), with: .color(Color(white: checker)))
                    }
                }
            }

            // 2. Subtle hairline pixel grid lines.
            var gridPath = Path()
            for i in 1..<grid {
                let x = round(CGFloat(i) * cellW * 2) / 2
                gridPath.move(to: CGPoint(x: x, y: 0))
                gridPath.addLine(to: CGPoint(x: x, y: size.height))
                let y = round(CGFloat(i) * cellH * 2) / 2
                gridPath.move(to: CGPoint(x: 0, y: y))
                gridPath.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(gridPath, with: .color(.white.opacity(0.14)), lineWidth: 0.5)
            context.stroke(gridPath, with: .color(.black.opacity(0.10)), lineWidth: 0.5)

            // 3. Adaptive high-contrast target pixel reticle in the exact center.
            let centerIndex = grid / 2
            let targetRect = CGRect(
                x: CGFloat(centerIndex) * cellW,
                y: CGFloat(centerIndex) * cellH,
                width: cellW,
                height: cellH
            )
            let outerRect = targetRect.insetBy(dx: -1.0, dy: -1.0)
            let innerRect = targetRect.insetBy(dx: 0.5, dy: 0.5)
            let radius = min(3.0, cellW * 0.22)
            let outerColor: Color = sample.center.isLight ? .white.opacity(0.82) : .black.opacity(0.65)
            let innerColor: Color = sample.center.isLight ? .black.opacity(0.88) : .white.opacity(0.96)
            context.stroke(Path(roundedRect: outerRect, cornerRadius: radius + 0.75), with: .color(outerColor), lineWidth: 1.5)
            context.stroke(Path(roundedRect: innerRect, cornerRadius: radius), with: .color(innerColor), lineWidth: 1.5)
        }
    }
}
