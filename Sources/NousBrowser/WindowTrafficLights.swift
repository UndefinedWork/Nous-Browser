import AppKit
import SwiftUI

/// Close, minimize and zoom in the sidebar (Settings → Appearance → Show
/// window buttons), using AppKit's own traffic-light buttons. The title bar
/// keeps (and keeps re-laying out) its set, so this view hides that set and
/// shows a fresh system set made for the window: the native look, the grey of
/// an inactive window, the native actions (green follows the system's
/// full-screen/zoom setting) and accessibility, while following the
/// sidebar's layout. `diameter` scales them for the icon rail.
///
/// The buttons draw their ×, – and arrow symbols when the window's frame view
/// says the pointer is over their group; `GroupHoverHook` answers that for
/// this set (see there).
struct WindowTrafficLights: View {
    var diameter: CGFloat = 14
    var spacing: CGFloat = 9

    var body: some View {
        NativeWindowButtons(diameter: diameter, spacing: spacing)
            .frame(width: diameter * 3 + spacing * 2, height: diameter)
    }
}

struct NativeWindowButtons: NSViewRepresentable {
    let diameter: CGFloat
    let spacing: CGFloat

    func makeNSView(context: Context) -> HostView {
        GroupHoverHook.install()
        return HostView()
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.diameter = diameter
        view.spacing = spacing
        view.needsLayout = true
    }

    static func dismantleNSView(_ view: HostView, coordinator: ()) { view.removeButtons() }

    final class HostView: NSView {
        /// Lets the window leave these alone when it hides its title-bar set.
        static let identifier = NSUserInterfaceItemIdentifier("NousWindowButtonsHost")
        private static let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        var diameter: CGFloat = 14
        var spacing: CGFloat = 9
        private var buttons: [NSButton] = []
        /// The title bar's set, captured before this view adds its own (the
        /// window may report either set afterwards).
        private var titlebarButtons: [NSButton] = []
        private var nativeSize = NSSize(width: 14, height: 14)
        private var observers: [NSObjectProtocol] = []
        private weak var hostWindow: NSWindow?
        private var tracking: NSTrackingArea?
        /// The pointer is over this set; read by `GroupHoverHook`.
        private(set) var isPointerInside = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            identifier = Self.identifier
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            if buttons.isEmpty || hostWindow !== window { makeButtons(for: window) }
            hostWindow = window
            hideTitlebarButtons()
            // Redraw for the inactive-window grey, hide in full screen; AppKit
            // may also show its title-bar set again after these changes.
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                         NSWindow.didResizeNotification, NSWindow.willEnterFullScreenNotification,
                         NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.hideTitlebarButtons()
                        self?.buttons.forEach { $0.needsDisplay = true }
                    }
                })
            }
        }

        private func makeButtons(for window: NSWindow) {
            titlebarButtons = Self.kinds.compactMap { window.standardWindowButton($0) }.filter { $0.superview !== self }
            buttons.forEach { $0.removeFromSuperview() }
            buttons = Self.kinds.compactMap { NSWindow.standardWindowButton($0, for: window.styleMask) }
            if let size = buttons.first?.frame.size, size.width > 0 { nativeSize = size }
            buttons.forEach(addSubview)
            needsLayout = true
        }

        /// Like the title bar's, they step aside in full screen.
        private func hideTitlebarButtons() {
            titlebarButtons.forEach { $0.isHidden = true }
            let fullScreen = window?.styleMask.contains(.fullScreen) == true
            buttons.forEach { $0.isHidden = fullScreen }
        }

        func removeButtons() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            buttons.forEach { $0.removeFromSuperview() }
            buttons = []
            hostWindow = nil
        }

        override func layout() {
            super.layout()
            let height = nativeSize.height * diameter / nativeSize.width
            for (index, button) in buttons.enumerated() {
                button.frame = NSRect(x: CGFloat(index) * (diameter + spacing), y: (bounds.height - height) / 2,
                                      width: diameter, height: height)
                // Scales drawing and hit-testing together (the icon rail uses 10pt).
                button.bounds = NSRect(origin: .zero, size: nativeSize)
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { setPointerInside(true) }
        override func mouseExited(with event: NSEvent) { setPointerInside(false) }

        private func setPointerInside(_ inside: Bool) {
            guard inside != isPointerInside else { return }
            isPointerInside = inside
            // Each system button re-reads the group's hover state (answered by
            // `GroupHoverHook`) when told the pointer entered or left.
            let update = NSSelectorFromString("mouseEnteredOrExited")
            for button in buttons {
                if button.responds(to: update) { button.perform(update) }
                button.needsDisplay = true
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only the buttons take clicks; the gaps between them stay draggable.
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }
    }
}

/// AppKit's traffic-light buttons ask the window's frame view (`NSThemeFrame`,
/// `-_mouseInGroup:`) whether the pointer is over their group before drawing
/// their symbols, and the frame view only knows its title-bar group. This
/// answers for buttons hosted in the sidebar and leaves every other answer to
/// AppKit. If a future macOS renames the class or method, nothing is hooked
/// and the sidebar buttons simply draw without symbols.
@MainActor
enum GroupHoverHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let selector = NSSelectorFromString("_mouseInGroup:")
        guard let frameClass = NSClassFromString("NSThemeFrame"),
              let method = class_getInstanceMethod(frameClass, selector),
              String(cString: method_getTypeEncoding(method)!).hasPrefix("B") ||
              String(cString: method_getTypeEncoding(method)!).hasPrefix("c") else { return }
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject?) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (AnyObject, AnyObject?) -> Bool = { frame, button in
            if let host = (button as? NSView)?.superview as? NativeWindowButtons.HostView {
                return MainActor.assumeIsolated { host.isPointerInside }
            }
            return original(frame, selector, button)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}
