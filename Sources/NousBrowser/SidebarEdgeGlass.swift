import SwiftUI

/// A soft glass veil over a scrolling sidebar, without a toolbar plate or border.
struct SidebarEdgeGlass: View {
    enum Edge {
        case top
        case bottom
    }

    let edge: Edge
    let buttonCenters: [CGFloat]
    var height: CGFloat = 96
    var controlCenterFromEdge: CGFloat = 34

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private var fogColor: Color {
        colorScheme == .dark ? BrowserDesign.darkWindowBacking : BrowserDesign.lightWindowBacking
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if reduceTransparency {
                    Rectangle().fill(fogColor.opacity(0.96))
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                }

                ForEach(Array(buttonCenters.enumerated()), id: \.offset) { _, centerX in
                    RadialGradient(
                        stops: [
                            .init(color: fogColor.opacity(reduceTransparency ? 0.16 : 0.26), location: 0),
                            .init(color: fogColor.opacity(reduceTransparency ? 0.08 : 0.13), location: 0.38),
                            .init(color: fogColor.opacity(0), location: 1)
                        ],
                        center: UnitPoint(
                            x: min(1, max(0, centerX / max(1, geometry.size.width))),
                            y: edge == .top ? controlCenterY : 1 - controlCenterY
                        ),
                        startRadius: 0,
                        endRadius: 88
                    )
                }
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white.opacity(0.98), location: 0.22),
                        .init(color: .white.opacity(0.88), location: 0.43),
                        .init(color: .white.opacity(0.35), location: 0.62),
                        .init(color: .white.opacity(0.08), location: 0.77),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: edge == .top ? .top : .bottom,
                    endPoint: edge == .top ? .bottom : .top
                )
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var controlCenterY: CGFloat {
        min(0.45, controlCenterFromEdge / max(1, height))
    }
}
