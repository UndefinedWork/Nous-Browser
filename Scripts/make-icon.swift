import AppKit
import Foundation

guard CommandLine.arguments.count > 1 else {
    fatalError("Usage: make-icon.swift output-directory [source-image]")
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let projectDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let sourceURL = CommandLine.arguments.count > 2
    ? URL(fileURLWithPath: CommandLine.arguments[2])
    : projectDirectory.appendingPathComponent("Resources/AppIcon.png")
guard let sourceImage = NSImage(contentsOf: sourceURL), sourceImage.size.width > 0, sourceImage.size.height > 0 else {
    fatalError("Could not read app icon source: \(sourceURL.path)")
}

let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Keep the supplied artwork intact inside the standard macOS app-icon plate.
// The surrounding margin is transparent; no colors, highlights, or shadows are added.
let plateRect = NSRect(x: 64, y: 64, width: 896, height: 896)
let sourceScale = min(plateRect.width / sourceImage.size.width, plateRect.height / sourceImage.size.height)
let drawingSize = NSSize(width: sourceImage.size.width * sourceScale, height: sourceImage.size.height * sourceScale)
let drawingRect = NSRect(
    x: plateRect.midX - drawingSize.width / 2,
    y: plateRect.midY - drawingSize.height / 2,
    width: drawingSize.width,
    height: drawingSize.height
)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let outputScale = CGFloat(pixels) / 1024
        context.cgContext.scaleBy(x: outputScale, y: outputScale)
        NSBezierPath(roundedRect: plateRect, xRadius: 205, yRadius: 205).addClip()
        sourceImage.draw(in: drawingRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let url = iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
