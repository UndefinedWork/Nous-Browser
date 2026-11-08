import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

// One Core Image pipeline renders both the editor preview (as the player's
// video composition) and the export, so what you see is what you get.

nonisolated struct ZoomSegment: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double
    var scale: Double
}

nonisolated struct RecordingDocument: Codable, Equatable, Sendable {
    var style = CaptureStyle.framed
    var trimStart: Double = 0
    var trimEnd: Double?
    var cursor = CursorTrack()
    var showsCursor = true
    var cursorScale: Double = 1.5
    var cursorSmoothing: Double = 0.5
    var clickEffect = true
    var zooms: [ZoomSegment] = []
    var zoomScale: Double = 1.8
    var zoomsGenerated = false

    var hasCursorTrack: Bool { !cursor.samples.isEmpty }

    /// Screen Studio-style: zoom in around each burst of clicks.
    static func autoZooms(clicks: [CursorTrack.Sample], duration: Double, scale: Double) -> [ZoomSegment] {
        var segments: [ZoomSegment] = []
        for click in clicks.sorted(by: { $0.t < $1.t }) {
            let start = max(0, click.t - 0.4), end = min(duration, click.t + 1.9)
            if var last = segments.last, start <= last.end + 0.7 {
                last.end = max(last.end, end)
                segments[segments.count - 1] = last
            } else {
                segments.append(ZoomSegment(start: start, end: end, scale: scale))
            }
        }
        return segments.filter { $0.end - $0.start > 0.3 }
    }
}

/// An immutable snapshot handed to the compositor's render queue.
nonisolated struct RecordingRenderSettings: Sendable {
    var document: RecordingDocument
    var sourceSize: CGSize
    var renderSize: CGSize
    /// Composition time + offset = source time (export starts at the trim).
    var timeOffset: Double

    static let rampDuration = 0.55

    func layout() -> (content: CGRect, scale: CGFloat) {
        let base = document.style.layout(content: sourceSize)
        let k = renderSize.width / max(base.canvas.width, 1)
        let rect = base.content
        // Core Image origin is bottom-left.
        let content = CGRect(x: rect.minX * k, y: renderSize.height - (rect.maxY * k), width: rect.width * k, height: rect.height * k)
        return (content, k)
    }

    private static func smoothstep(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// Averaged pointer over a short window: steadier than the raw track.
    func smoothedPointer(at time: Double, window: Double) -> CGPoint? {
        guard document.hasCursorTrack else { return nil }
        let steps = 8
        var x = 0.0, y = 0.0, weights = 0.0
        for step in 0..<steps {
            let t = time - window * Double(step) / Double(steps - 1)
            guard let p = document.cursor.position(at: t) else { continue }
            let w = Double(steps - step)
            x += p.x * w; y += p.y * w; weights += w
        }
        return weights > 0 ? CGPoint(x: x / weights, y: y / weights) : nil
    }

    func zoom(at time: Double) -> (scale: Double, focus: CGPoint) {
        var scale = 1.0
        for segment in document.zooms {
            let up = Self.smoothstep((time - (segment.start - Self.rampDuration * 0.5)) / Self.rampDuration)
            let down = 1 - Self.smoothstep((time - segment.end) / Self.rampDuration)
            let weight = min(up, down)
            scale = max(scale, 1 + (segment.scale - 1) * weight)
        }
        guard scale > 1.001 else { return (1, CGPoint(x: 0.5, y: 0.5)) }
        var focus = smoothedPointer(at: time, window: 0.9) ?? CGPoint(x: 0.5, y: 0.5)
        let half = 0.5 / scale
        focus.x = min(max(focus.x, half), 1 - half)
        focus.y = min(max(focus.y, half), 1 - half)
        return (scale, focus)
    }
}

final class RecordingInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let settings: RecordingRenderSettings
    let trackID: CMPersistentTrackID

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, settings: RecordingRenderSettings) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.settings = settings
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
    }
}

final class RecordingCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let lock = NSLock()
    private var renderContext: AVVideoCompositionRenderContext?

    nonisolated(unsafe) private static var cursorCache: (image: CIImage, hotSpot: CGPoint, size: CGSize)?

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        lock.lock(); renderContext = newRenderContext; lock.unlock()
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? RecordingInstruction,
              let source = request.sourceFrame(byTrackID: instruction.trackID) else {
            request.finish(with: NSError(domain: "Nous.Recording", code: 1))
            return
        }
        lock.lock(); let renderContext = self.renderContext; lock.unlock()
        guard let output = renderContext?.newPixelBuffer() else {
            request.finish(with: NSError(domain: "Nous.Recording", code: 2))
            return
        }
        let time = request.compositionTime.seconds + instruction.settings.timeOffset
        let image = Self.compose(frame: CIImage(cvPixelBuffer: source), at: time, settings: instruction.settings)
        context.render(image, to: output, bounds: CGRect(origin: .zero, size: instruction.settings.renderSize), colorSpace: colorSpace)
        request.finish(withComposedVideoFrame: output)
    }

    func cancelAllPendingVideoCompositionRequests() {}

    /// AppKit images are read on the main thread before any frame renders.
    @MainActor static func prepareCursor() { _ = cursorImage() }

    private static func cursorImage() -> (image: CIImage, hotSpot: CGPoint, size: CGSize) {
        if let cursorCache { return cursorCache }
        let cursor = NSCursor.arrow
        let size = cursor.image.size
        // Rasterize at 4× so a large cursor stays sharp in 4K exports.
        var image = CIImage.empty()
        let width = max(1, Int(size.width * 4)), height = max(1, Int(size.height * 4))
        if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.scaleBy(x: 4, y: 4)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            cursor.image.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            if let cg = context.makeImage() { image = CIImage(cgImage: cg) }
        }
        let value = (image, cursor.hotSpot, size)
        cursorCache = value
        return value
    }

    static func compose(frame: CIImage, at time: Double, settings: RecordingRenderSettings) -> CIImage {
        let canvas = CGRect(origin: .zero, size: settings.renderSize)
        let document = settings.document
        let style = document.style
        let content = settings.layout().content
        let source = frame.extent
        let sw = source.width, sh = source.height

        // Zoom: the visible part of the frame fills the content rectangle.
        let zoom = settings.zoom(at: time)
        let visible = CGSize(width: sw / zoom.scale, height: sh / zoom.scale)
        let vx = zoom.focus.x * sw - visible.width / 2
        let vy = (1 - zoom.focus.y) * sh - visible.height / 2
        let sx = content.width / visible.width, sy = content.height / visible.height
        let transform = CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: content.minX - (source.minX + vx) * sx, ty: content.minY - (source.minY + vy) * sy)
        var video = frame.transformed(by: transform).cropped(to: content)

        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * sw + source.minX, y: (1 - p.y) * sh + source.minY).applying(transform)
        }
        let pointsToPixels = document.cursor.areaWidth > 0 ? sw / document.cursor.areaWidth : 2

        if document.clickEffect, document.showsCursor {
            for click in document.cursor.clicks where time >= click.t && time - click.t < 0.5 {
                let progress = (time - click.t) / 0.5
                let center = map(CGPoint(x: click.x, y: click.y))
                let radius = CGFloat(14 + 26 * progress) * pointsToPixels * sx / 2
                let ring = CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": CIVector(cgPoint: center), "inputRadius0": radius * 0.7, "inputRadius1": radius,
                    "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.55 * (1 - progress)),
                    "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0)])!.outputImage!
                video = ring.cropped(to: content).composited(over: video)
            }
        }
        if document.showsCursor, let pointer = settings.smoothedPointer(at: time, window: 0.12 + document.cursorSmoothing * 0.3) {
            let cursor = cursorImage()
            let target = cursor.size.width * pointsToPixels * sx * document.cursorScale
            let scale = target / max(cursor.image.extent.width, 1)
            let tip = map(pointer)
            let hot = CGPoint(x: cursor.hotSpot.x / cursor.size.width * cursor.image.extent.width * scale,
                              y: cursor.hotSpot.y / cursor.size.height * cursor.image.extent.height * scale)
            let placed = cursor.image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: tip.x - hot.x, y: tip.y - (cursor.image.extent.height * scale - hot.y)))
            video = placed.composited(over: video).cropped(to: content)
        }

        let radius = min(content.width, content.height) * style.cornerRadius
        if radius > 0.5 {
            let mask = CIFilter.roundedRectangleGenerator()
            mask.extent = content
            mask.radius = Float(radius)
            mask.color = .white
            if let maskImage = mask.outputImage {
                video = video.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: maskImage])
            }
        }

        var background = style.background.ciImage(extent: canvas)
        if !style.background.isNone, style.shadow > 0 {
            let shorter = min(content.width, content.height)
            let shape = CIFilter.roundedRectangleGenerator()
            shape.extent = content.offsetBy(dx: 0, dy: -shorter * 0.012 * style.shadow)
            shape.radius = Float(radius)
            shape.color = CIColor(red: 0, green: 0, blue: 0, alpha: 0.38 * style.shadow)
            if let shadow = shape.outputImage?.applyingGaussianBlur(sigma: shorter * 0.03 * style.shadow) {
                background = shadow.composited(over: background)
            }
        }
        return video.composited(over: background).cropped(to: canvas)
    }
}

enum RecordingComposer {
    /// Even dimensions for H.264; at most `maxWidth` wide.
    static func renderSize(source: CGSize, style: CaptureStyle, maxWidth: CGFloat) -> CGSize {
        let canvas = style.layout(content: source).canvas
        let scale = min(1, maxWidth / max(canvas.width, 1))
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * scale / 2).rounded() * 2) }
        return CGSize(width: even(canvas.width), height: even(canvas.height))
    }

    static func videoComposition(track: CMPersistentTrackID, duration: CMTime, settings: RecordingRenderSettings) -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = RecordingCompositor.self
        composition.renderSize = settings.renderSize
        composition.frameDuration = CMTime(value: 1, timescale: 60)
        composition.instructions = [RecordingInstruction(timeRange: CMTimeRange(start: .zero, duration: duration),
                                                         trackID: track, settings: settings)]
        return composition
    }
}
