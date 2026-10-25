import AppKit
import SwiftUI

/// A native divider catches dragging before the adjacent webpage or window background.
struct SidebarResizeHandle: NSViewRepresentable {
    let width: CGFloat
    let onBegin: () -> Void
    let onResize: (CGFloat) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> ResizeView {
        let view = ResizeView()
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel(L10n.string("Resize Sidebar"))
        view.setAccessibilityHelp(L10n.string("Drag to resize the sidebar. Double-click to restore the default width."))
        return view
    }

    func updateNSView(_ view: ResizeView, context: Context) {
        view.currentWidth = width
        view.onBegin = onBegin
        view.onResize = onResize
        view.onEnd = onEnd
        view.onReset = onReset
        view.onHover = onHover
        view.setAccessibilityValue(Int(width))
    }

    final class ResizeView: NSView {
        var currentWidth: CGFloat = 243
        var onBegin: (() -> Void)?
        var onResize: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        var onReset: (() -> Void)?
        var onHover: ((Bool) -> Void)?
        private var dragStartX: CGFloat?
        private var dragStartWidth: CGFloat = 0
        private var tracking: NSTrackingArea?

        override var mouseDownCanMoveWindow: Bool { false }
        override var acceptsFirstResponder: Bool { false }
        override func isAccessibilityElement() -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
                                      owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { if dragStartX == nil { onHover?(false) } }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onReset?()
                return
            }
            dragStartX = event.locationInWindow.x
            dragStartWidth = currentWidth
            onBegin?()
            NSCursor.resizeLeftRight.set()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragStartX else { return }
            onResize?(dragStartWidth + event.locationInWindow.x - dragStartX)
        }

        override func mouseUp(with event: NSEvent) {
            guard dragStartX != nil else { return }
            dragStartX = nil
            onEnd?()
            onHover?(bounds.contains(convert(event.locationInWindow, from: nil)))
            window?.invalidateCursorRects(for: self)
        }

        override func accessibilityPerformIncrement() -> Bool {
            onResize?(currentWidth + 16)
            return true
        }

        override func accessibilityPerformDecrement() -> Bool {
            onResize?(currentWidth - 16)
            return true
        }
    }
}
