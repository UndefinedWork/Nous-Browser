import AppKit
import CoreImage
import SwiftUI

/// sRGB components, so a style renders the same in SwiftUI, Core Graphics and Core Image.
nonisolated struct RGBA: Codable, Hashable, Sendable {
    var r: Double, g: Double, b: Double, a: Double = 1

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(hex: UInt32, alpha: Double = 1) {
        r = Double((hex >> 16) & 0xff) / 255; g = Double((hex >> 8) & 0xff) / 255; b = Double(hex & 0xff) / 255; a = alpha
    }
    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        r = resolved.redComponent; g = resolved.greenComponent; b = resolved.blueComponent; a = resolved.alphaComponent
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var ciColor: CIColor { CIColor(red: r, green: g, blue: b, alpha: a, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)! }
}

nonisolated enum CaptureBackground: Codable, Hashable, Sendable {
    case none
    case solid(RGBA)
    case gradient(Int)

    static let gradients: [[RGBA]] = [
        [RGBA(hex: 0x7F7FD5), RGBA(hex: 0x86A8E7), RGBA(hex: 0x91EAE4)],
        [RGBA(hex: 0xFF9A8B), RGBA(hex: 0xFF6A88), RGBA(hex: 0xFF99AC)],
        [RGBA(hex: 0x43CEA2), RGBA(hex: 0x185A9D)],
        [RGBA(hex: 0xF6D365), RGBA(hex: 0xFDA085)],
        [RGBA(hex: 0xA18CD1), RGBA(hex: 0xFBC2EB)],
        [RGBA(hex: 0x0F2027), RGBA(hex: 0x203A43), RGBA(hex: 0x2C5364)],
        [RGBA(hex: 0xE0EAFC), RGBA(hex: 0xCFDEF3)],
        [RGBA(hex: 0x84FAB0), RGBA(hex: 0x8FD3F4)],
        [RGBA(hex: 0xFC5C7D), RGBA(hex: 0x6A82FB)],
        [RGBA(hex: 0x232526), RGBA(hex: 0x414345)],
    ]
    static let solids: [RGBA] = [RGBA(hex: 0xFFFFFF), RGBA(hex: 0xF2F2F7), RGBA(hex: 0xD1D1D6), RGBA(hex: 0x1C1C1E), RGBA(hex: 0x000000)]

    var isNone: Bool { self == .none }

    @ViewBuilder var view: some View {
        switch self {
        case .none: Color.clear
        case .solid(let color): color.color
        case .gradient(let index):
            LinearGradient(colors: Self.gradients[index % Self.gradients.count].map(\.color),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    /// For video frames; `extent` is the output canvas.
    func ciImage(extent: CGRect) -> CIImage {
        switch self {
        case .none: return CIImage(color: .black).cropped(to: extent)
        case .solid(let color): return CIImage(color: color.ciColor).cropped(to: extent)
        case .gradient(let index):
            let stops = Self.gradients[index % Self.gradients.count]
            // Core Image's linear gradient has two stops; blend a middle stop for three-colour sets.
            let start = CGPoint(x: extent.minX, y: extent.maxY), end = CGPoint(x: extent.maxX, y: extent.minY)
            func linear(_ a: RGBA, _ b: RGBA, _ p0: CGPoint, _ p1: CGPoint) -> CIImage {
                let filter = CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": CIVector(cgPoint: p0), "inputPoint1": CIVector(cgPoint: p1),
                    "inputColor0": a.ciColor, "inputColor1": b.ciColor])!
                return filter.outputImage!.cropped(to: extent)
            }
            if stops.count < 3 { return linear(stops[0], stops[stops.count - 1], start, end) }
            // Blend two full-length gradients by position: smooth, with no seam at the middle stop.
            let first = linear(stops[0], stops[1], start, end)
            let second = linear(stops[1], stops[2], start, end)
            let mask = linear(RGBA(0, 0, 0), RGBA(1, 1, 1), start, end)
            return second.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: first, kCIInputMaskImageKey: mask])
        }
    }
}

nonisolated enum CaptureAspect: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto, square, fourThree, sixteenNine, nineSixteen
    var id: String { rawValue }
    var ratio: Double? {
        switch self {
        case .auto: nil
        case .square: 1
        case .fourThree: 4.0 / 3.0
        case .sixteenNine: 16.0 / 9.0
        case .nineSixteen: 9.0 / 16.0
        }
    }
    var label: String {
        switch self {
        case .auto: L10n.string("Auto")
        case .square: "1:1"
        case .fourThree: "4:3"
        case .sixteenNine: "16:9"
        case .nineSixteen: "9:16"
        }
    }
}

/// The frame around a capture: background, padding, corners and shadow.
nonisolated struct CaptureStyle: Codable, Equatable, Sendable {
    var background: CaptureBackground = .none
    /// Fraction of the content's shorter side.
    var padding: Double = 0
    var cornerRadius: Double = 0
    var shadow: Double = 0.5
    var aspect: CaptureAspect = .auto

    static let framed = CaptureStyle(background: .gradient(0), padding: 0.08, cornerRadius: 0.018, shadow: 0.6)

    var isPlain: Bool { background.isNone && padding == 0 && cornerRadius == 0 && aspect == .auto }

    /// Output canvas and the content's rectangle inside it (top-left origin).
    func layout(content: CGSize) -> (canvas: CGSize, content: CGRect) {
        let shorter = min(content.width, content.height)
        let pad = background.isNone && aspect == .auto ? 0 : shorter * padding
        var canvas = CGSize(width: content.width + pad * 2, height: content.height + pad * 2)
        if let ratio = aspect.ratio {
            if canvas.width / canvas.height < ratio { canvas.width = canvas.height * ratio }
            else { canvas.height = canvas.width / ratio }
        }
        canvas = CGSize(width: canvas.width.rounded(), height: canvas.height.rounded())
        let origin = CGPoint(x: ((canvas.width - content.width) / 2).rounded(), y: ((canvas.height - content.height) / 2).rounded())
        return (canvas, CGRect(origin: origin, size: content))
    }

    func radius(for content: CGSize) -> CGFloat { min(content.width, content.height) * cornerRadius }
}

/// Swatches shared by both editors' inspectors.
struct CaptureBackgroundPicker: View {
    @Binding var background: CaptureBackground

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 6), spacing: 8) {
            swatch(.none) {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.06))
                    Image(systemName: "nosign").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            ForEach(CaptureBackground.gradients.indices, id: \.self) { index in
                swatch(.gradient(index)) { CaptureBackground.gradient(index).view.clipShape(Circle()) }
            }
            ForEach(CaptureBackground.solids, id: \.self) { color in
                swatch(.solid(color)) { Circle().fill(color.color) }
            }
        }
    }

    private func swatch<Content: View>(_ value: CaptureBackground, @ViewBuilder content: () -> Content) -> some View {
        Button { withAnimation(BrowserMotion.spring) { background = value } } label: {
            content()
                .frame(width: 26, height: 26)
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
                .padding(2)
                .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: background == value ? 2 : 0) }
                .scaleEffect(background == value ? 1.06 : 1)
                .animation(BrowserMotion.interaction, value: background == value)
        }
        .buttonStyle(.plain)
    }
}

/// A labelled slider row, compact like macOS inspector panels.
struct InspectorSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Slider(value: $value, in: range).controlSize(.small)
        }
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content
        }
    }
}
