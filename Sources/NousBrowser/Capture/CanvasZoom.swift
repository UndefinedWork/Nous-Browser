import SwiftUI

/// Zoom for the screenshot and recording editors. `zoom` is relative to
/// "fit": 1 shows the whole canvas, larger values magnify it and the canvas
/// scrolls (two-finger scroll pans; dragging stays an editing gesture).
enum CanvasZoom {
    static let range: ClosedRange<CGFloat> = 0.25...8
    private static let steps: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8]

    static func clamp(_ value: CGFloat) -> CGFloat { min(range.upperBound, max(range.lowerBound, value)) }
    static func zoomedIn(_ value: CGFloat) -> CGFloat { steps.first { $0 > value + 0.01 } ?? range.upperBound }
    static func zoomedOut(_ value: CGFloat) -> CGFloat { steps.last { $0 < value - 0.01 } ?? range.lowerBound }

    /// ⌘= / ⌘+ / ⌘- / ⌘0. Returns nil when the key is not a zoom key.
    static func zoom(for character: String, current: CGFloat) -> CGFloat? {
        switch character {
        case "=", "+": zoomedIn(current)
        case "-", "_": zoomedOut(current)
        case "0": 1
        default: nil
        }
    }
}

/// Lays the canvas out at `fitScale × zoom` inside a scroll view that fills
/// `viewport`, centred while it is smaller than the viewport.
struct ZoomableCanvas<Content: View>: View {
    let canvas: CGSize
    let fitScale: CGFloat
    @Binding var zoom: CGFloat
    let viewport: CGSize
    @ViewBuilder let content: (CGFloat) -> Content
    @State private var pinchStart: CGFloat?

    var body: some View {
        let scale = fitScale * zoom
        let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        ScrollView([.horizontal, .vertical]) {
            content(scale)
                .frame(width: size.width, height: size.height)
                .padding(24)
                .frame(minWidth: viewport.width, minHeight: viewport.height)
        }
        .scrollIndicators(zoom > 1 ? .automatic : .hidden)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: max(0, viewport.width), height: max(0, viewport.height))
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let start = pinchStart ?? zoom
                    pinchStart = start
                    zoom = CanvasZoom.clamp(start * value.magnification)
                }
                .onEnded { _ in pinchStart = nil }
        )
    }
}

/// − 100% + in a glass capsule; clicking the percentage fits the canvas.
struct CanvasZoomControl: View {
    @Binding var zoom: CGFloat
    /// The effective scale (fit × zoom), shown as a percentage of actual size.
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 2) {
            button("minus", L10n.string("Zoom Out") + "  ⌘−") { zoom = CanvasZoom.zoomedOut(zoom) }
                .disabled(zoom <= CanvasZoom.range.lowerBound)
            Button { withAnimation(BrowserMotion.spring) { zoom = 1 } } label: {
                Text("\(Int((scale * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .frame(minWidth: 42)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string("Zoom to Fit") + "  ⌘0")
            button("plus", L10n.string("Zoom In") + "  ⌘+") { zoom = CanvasZoom.zoomedIn(zoom) }
                .disabled(zoom >= CanvasZoom.range.upperBound)
        }
        .padding(.horizontal, 4)
        .glassEffect(.regular, in: Capsule())
        .animation(BrowserMotion.spring, value: zoom)
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button { withAnimation(BrowserMotion.spring) { action() } } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
