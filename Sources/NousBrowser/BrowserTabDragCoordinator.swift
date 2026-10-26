import AppKit
import Observation
import SwiftUI

/// One drag image follows the pointer across window boundaries. Sidebar views
/// advertise their actual native geometry; they never exchange serialized tabs.
@MainActor
@Observable
final class BrowserTabDragCoordinator {
    struct Target: Equatable {
        let controllerID: ObjectIdentifier
        let index: Int
    }

    private(set) var tabID: UUID?
    private(set) var sourceID: ObjectIdentifier?
    private(set) var target: Target?
    private(set) var isSettling = false

    @ObservationIgnored private var endpoints: [ObjectIdentifier: Endpoint] = [:]
    @ObservationIgnored private var tab: BrowserTab?
    @ObservationIgnored private var panel: DragPanel?
    @ObservationIgnored private var hostingView: NSHostingView<AnyView>?
    @ObservationIgnored private var grabOffset = CGPoint.zero
    @ObservationIgnored private var pointer = NSPoint.zero
    @ObservationIgnored private var pendingLanding: Target?
    @ObservationIgnored private var springTimer: Timer?
    @ObservationIgnored private var velocity = CGPoint.zero
    @ObservationIgnored private var widthVelocity: CGFloat = 0
    @ObservationIgnored private var lastSpringTime: TimeInterval = 0
    @ObservationIgnored private var landingStarted: TimeInterval = 0
    private let imagePadding: CGFloat = 20

    private final class Endpoint {
        weak var controller: BrowserController?
        let reference: SidebarDragWindowReference
        var viewport: CGSize
        var metrics: SidebarScrollMetrics
        init(controller: BrowserController, reference: SidebarDragWindowReference,
             viewport: CGSize, metrics: SidebarScrollMetrics) {
            self.controller = controller
            self.reference = reference
            self.viewport = viewport
            self.metrics = metrics
        }
    }

    func register(_ controller: BrowserController, reference: SidebarDragWindowReference,
                  viewport: CGSize, metrics: SidebarScrollMetrics) {
        let id = ObjectIdentifier(controller)
        if let endpoint = endpoints[id] {
            endpoint.viewport = viewport
            endpoint.metrics = metrics
        } else {
            endpoints[id] = Endpoint(controller: controller, reference: reference, viewport: viewport, metrics: metrics)
        }
        if tabID != nil, !isSettling { updateTarget(at: pointer) }
    }

    func unregister(_ controller: BrowserController) {
        let id = ObjectIdentifier(controller)
        endpoints[id] = nil
        if pendingLanding?.controllerID == id { cancel() }
        else if sourceID == id, !isSettling { cancel() }
        else if target?.controllerID == id, !isSettling { target = nil }
    }

    func begin(tab: BrowserTab, source: BrowserController, at point: NSPoint,
               rowSize: CGSize, grabOffset: CGPoint) {
        cancel()
        self.tab = tab
        tabID = tab.id
        sourceID = ObjectIdentifier(source)
        self.grabOffset = grabOffset
        pointer = point
        let panel = DragPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.setAccessibilityElement(false)
        let size = CGSize(width: rowSize.width + imagePadding * 2, height: rowSize.height + imagePadding * 2)
        panel.setFrame(NSRect(origin: imageOrigin(for: point, rowHeight: rowSize.height), size: size), display: false)
        let hostingView = NSHostingView(rootView: floatingImage(tab, settling: false))
        panel.contentView = hostingView
        self.hostingView = hostingView
        self.panel = panel
        panel.orderFrontRegardless()
        updateTarget(at: point)
    }

    func update(at point: NSPoint) {
        guard tabID != nil, !isSettling, point.x.isFinite, point.y.isFinite else { return }
        pointer = point
        panel?.setFrameOrigin(imageOrigin(for: point, rowHeight: BrowserDesign.rowHeight))
        updateTarget(at: point)
    }

    func destination(at point: NSPoint) -> (controller: BrowserController, index: Int)? {
        update(at: point)
        guard let target, let controller = endpoints[target.controllerID]?.controller else { return nil }
        return (controller, target.index)
    }

    func insertionIndex(in controller: BrowserController) -> Int? {
        guard tabID != nil, let target, target.controllerID == ObjectIdentifier(controller),
              sourceID != target.controllerID, !controller.model.tabs.contains(where: { $0.id == tabID }) else { return nil }
        return target.index
    }

    func hides(_ id: UUID) -> Bool { tabID == id }

    func incomingPointer(in controller: BrowserController) -> CGPoint? {
        guard !isSettling, target?.controllerID == ObjectIdentifier(controller),
              let endpoint = endpoints[ObjectIdentifier(controller)] else { return nil }
        return endpoint.reference.sidebarPoint(forScreenPoint: pointer)
    }

    /// Set this before moving the model: closing an emptied source window must
    /// not dismiss the floating image while its destination is mounting.
    func prepareForDrop() {
        guard tabID != nil else { return }
        isSettling = true
    }

    func completeTransfer(to controller: BrowserController, index: Int) {
        guard tabID != nil, panel != nil else { return }
        isSettling = true
        let landing = Target(controllerID: ObjectIdentifier(controller), index: index)
        target = landing
        pendingLanding = landing
        velocity = .zero
        widthVelocity = 0
        if let tab { hostingView?.rootView = floatingImage(tab, settling: true) }
        lastSpringTime = ProcessInfo.processInfo.systemUptime
        landingStarted = lastSpringTime
        springTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.springTick() }
        }
        springTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancel() {
        springTimer?.invalidate()
        springTimer = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        hostingView = nil
        tab = nil
        tabID = nil
        sourceID = nil
        target = nil
        pendingLanding = nil
        isSettling = false
    }

    private func imageOrigin(for point: NSPoint, rowHeight: CGFloat) -> NSPoint {
        NSPoint(x: point.x - grabOffset.x - imagePadding,
                y: point.y + grabOffset.y - rowHeight - imagePadding)
    }

    private func floatingImage(_ tab: BrowserTab, settling: Bool) -> AnyView {
        AnyView(SidebarFloatingTab(tab: tab, isSettling: settling)
            .frame(maxWidth: .infinity).frame(height: BrowserDesign.rowHeight)
            .padding(imagePadding).accessibilityHidden(true))
    }

    private func updateTarget(at point: NSPoint) {
        guard let tab, let sourceID else { return }
        // A point can be occluded by another app, Settings, or a page in front
        // of a sidebar. Consult AppKit's actual mouse hit window, not just the
        // application's window order or a window's partly-visible flag.
        var number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        if number == panel?.windowNumber {
            number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: number)
        }
        var proposed: Target?
        for (id, endpoint) in endpoints where id != sourceID {
            guard let controller = endpoint.controller, controller.model.isSidebarVisible,
                  let window = endpoint.reference.window, window.windowNumber == number,
                  window.isVisible, !window.isMiniaturized, window.attachedSheet == nil,
                  !controller.isAddressPresented,
                  let local = endpoint.reference.sidebarPoint(forScreenPoint: point),
                  CGRect(origin: .zero, size: endpoint.viewport).insetBy(dx: 6, dy: 12).contains(local),
                  local.y >= SidebarTabDragGeometry.contentInset - 8,
                  local.y <= endpoint.viewport.height - SidebarTabDragGeometry.contentInset + 8 else { continue }
            let raw = Int(((local.y - grabOffset.y + endpoint.metrics.offsetY
                            - SidebarTabDragGeometry.contentInset) / SidebarTabDragGeometry.stride).rounded())
            let pinnedCount = controller.model.tabs.prefix(while: \.isPinned).count
            let index = tab.isPinned ? min(max(0, raw), pinnedCount)
                : min(max(pinnedCount, raw), controller.model.tabs.count)
            proposed = Target(controllerID: id, index: index)
            break
        }
        if target != proposed { target = proposed }
    }

    private func springTick() {
        guard let panel, let landing = pendingLanding else { cancel(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if let endpoint = endpoints[landing.controllerID], let controller = endpoint.controller,
           !controller.model.tabs.contains(where: { $0.id == tabID }) || !controller.model.isSidebarVisible {
            cancel()
            return
        }
        guard let endpoint = endpoints[landing.controllerID],
              let point = endpoint.reference.screenPoint(forSidebarPoint:
                CGPoint(x: BrowserDesign.inset,
                        y: SidebarTabDragGeometry.contentInset + CGFloat(landing.index) * SidebarTabDragGeometry.stride
                            - endpoint.metrics.offsetY)) else {
            if now - landingStarted > 0.5 { cancel() }
            return
        }
        let destination = NSPoint(x: point.x - imagePadding,
                                  y: point.y - BrowserDesign.rowHeight - imagePadding)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let dt = CGFloat(min(1.0 / 30.0, max(1.0 / 240.0, now - lastSpringTime)))
        lastSpringTime = now
        let omega: CGFloat = 28
        let damping: CGFloat = 0.86
        var origin = panel.frame.origin
        let destinationWidth = max(0, endpoint.viewport.width - BrowserDesign.inset * 2) + imagePadding * 2
        var width = panel.frame.width
        velocity.x += (omega * omega * (destination.x - origin.x) - 2 * damping * omega * velocity.x) * dt
        velocity.y += (omega * omega * (destination.y - origin.y) - 2 * damping * omega * velocity.y) * dt
        origin.x += velocity.x * dt
        origin.y += velocity.y * dt
        widthVelocity += (omega * omega * (destinationWidth - width) - 2 * damping * omega * widthVelocity) * dt
        width += widthVelocity * dt
        panel.setFrame(NSRect(origin: reduced ? destination : origin,
                              size: CGSize(width: reduced ? destinationWidth : width, height: panel.frame.height)), display: true)
        if reduced || now - landingStarted > 0.48 ||
            (hypot(destination.x - origin.x, destination.y - origin.y) < 0.35 && hypot(velocity.x, velocity.y) < 3
                && abs(destinationWidth - width) < 0.35 && abs(widthVelocity) < 3) {
            panel.setFrame(NSRect(origin: destination, size: CGSize(width: destinationWidth, height: panel.frame.height)), display: true)
            cancel()
        }
    }

    private final class DragPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
}
