import AppKit
import SwiftUI

/// Close, minimize and zoom drawn in the sidebar (Settings → Appearance →
/// Show window buttons). AppKit's own buttons stay hidden: they sit in the
/// title bar and cannot follow the sidebar's layout. These behave the same:
/// grey while the window is inactive, symbols on hover, the green button
/// enters full screen (⌥-click zooms), and they hide in full screen.
struct WindowTrafficLights: View {
    var diameter: CGFloat = 14
    var spacing: CGFloat = 9
    @State private var window: NSWindow?
    @State private var isKey = true
    @State private var isFullScreen = false
    @State private var hovered = false

    var body: some View {
        HStack(spacing: spacing) {
            light(.close, color: Color(red: 1, green: 0.373, blue: 0.341), symbol: "xmark",
                  label: L10n.string("Close Window")) { window?.performClose(nil) }
            light(.minimize, color: Color(red: 0.996, green: 0.737, blue: 0.180), symbol: "minus",
                  label: L10n.string("Minimize")) { window?.performMiniaturize(nil) }
            light(.zoom, color: Color(red: 0.157, green: 0.784, blue: 0.251),
                  symbol: "arrow.up.left.and.arrow.down.right", label: L10n.string("Enter Full Screen")) {
                if NSEvent.modifierFlags.contains(.option) { window?.performZoom(nil) }
                else { window?.toggleFullScreen(nil) }
            }
        }
        .opacity(isFullScreen ? 0 : 1)
        .allowsHitTesting(!isFullScreen)
        .onHover { hovered = $0 }
        .background(WindowObserver(window: $window, isKey: $isKey, isFullScreen: $isFullScreen))
    }

    private enum Kind { case close, minimize, zoom }

    private func light(_ kind: Kind, color: Color, symbol: String, label: String,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(isKey || hovered ? color : Color.primary.opacity(0.16))
                Circle().strokeBorder(Color.black.opacity(isKey || hovered ? 0.12 : 0.06), lineWidth: 0.5)
                if hovered {
                    Image(systemName: symbol)
                        .font(.system(size: diameter * (kind == .zoom ? 0.42 : 0.5), weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.55))
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Tracks the hosting window's key and full-screen state.
private struct WindowObserver: NSViewRepresentable {
    @Binding var window: NSWindow?
    @Binding var isKey: Bool
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = { window, isKey, isFullScreen in
            self.window = window
            self.isKey = isKey
            self.isFullScreen = isFullScreen
        }
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {}

    final class ObserverView: NSView {
        var onChange: ((NSWindow?, Bool, Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                                              NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                                              NSWindow.willEnterFullScreenNotification]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            report()
        }

        private func report() {
            let window = self.window
            let fullScreen = window?.styleMask.contains(.fullScreen) == true
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(window, window?.isKeyWindow ?? false, fullScreen)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
