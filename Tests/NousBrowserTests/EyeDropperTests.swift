import CoreGraphics
import Foundation
import Testing
@testable import NousBrowser

@Suite("EyeDropper")
struct EyeDropperTests {
    @Test("Color formats sRGB hex, RGB and adaptive contrast")
    func colorFormattingAndContrast() {
        let blue = EyeDropperColor(red: 0x3B, green: 0x82, blue: 0xF6)
        #expect(blue.hexString == "#3B82F6")
        #expect(blue.rgbString == "59, 130, 246")
        #expect(!blue.isLight)

        let white = EyeDropperColor(red: 255, green: 255, blue: 255)
        #expect(white.hexString == "#FFFFFF")
        #expect(white.isLight)

        let black = EyeDropperColor(red: 0, green: 0, blue: 0)
        #expect(black.hexString == "#000000")
        #expect(!black.isLight)

        let yellow = EyeDropperColor(red: 250, green: 230, blue: 60)
        #expect(yellow.isLight)
    }

    @Test("Surface decodes sRGB CGImage accurately and maps AppKit Y-up coordinates")
    func surfaceDecodesAndMapsCoordinates() throws {
        // 4x2 pixel image in sRGB:
        // Top row (y=0 in CGImage, top of screenRect):    Red,   Green, Blue,  White
        // Bottom row (y=1 in CGImage, bottom of rect):    Black, Cyan,  Amber, Purple
        let expectedTop = [
            EyeDropperColor(red: 220, green: 40, blue: 50),
            EyeDropperColor(red: 30, green: 190, blue: 80),
            EyeDropperColor(red: 45, green: 120, blue: 245),
            EyeDropperColor(red: 255, green: 255, blue: 255),
        ]
        let expectedBottom = [
            EyeDropperColor(red: 0, green: 0, blue: 0),
            EyeDropperColor(red: 20, green: 210, blue: 220),
            EyeDropperColor(red: 240, green: 165, blue: 15),
            EyeDropperColor(red: 150, green: 60, blue: 200),
        ]
        let image = try makeSRGBImage(rows: [expectedTop, expectedBottom])
        // Retina 2x logical rect: 2pt wide x 1pt tall positioned on a secondary display at (-200, 100).
        let rect = CGRect(x: -200, y: 100, width: 2, height: 1)
        let surface = try #require(EyeDropperSurface(cgImage: image, screenRect: rect))

        // Top-left pixel (x=0, y=0) corresponds to AppKit (-199.9, 100.9).
        let topLeft = try #require(surface.sample(at: CGPoint(x: -199.9, y: 100.9), gridSize: 3))
        #expect(topLeft.center == expectedTop[0])
        #expect(topLeft.gridSize == 3)
        // 3x3 grid centered at (0, 0): top row & left col are nil; center is expectedTop[0];
        // right is expectedTop[1]; bottom is expectedBottom[0]; bottom-right is expectedBottom[1].
        #expect(topLeft.pixels[0] == nil)
        #expect(topLeft.pixels[3] == nil)
        #expect(topLeft.pixels[4] == expectedTop[0])
        #expect(topLeft.pixels[5] == expectedTop[1])
        #expect(topLeft.pixels[7] == expectedBottom[0])
        #expect(topLeft.pixels[8] == expectedBottom[1])

        // Bottom-right pixel (x=3, y=1) corresponds to AppKit (-198.1, 100.1).
        let bottomRight = try #require(surface.sample(at: CGPoint(x: -198.1, y: 100.1), gridSize: 3))
        #expect(bottomRight.center == expectedBottom[3])

        // Outside the surface returns nil.
        #expect(surface.sample(at: CGPoint(x: -201, y: 100.5), gridSize: 3) == nil)
        #expect(surface.sample(at: CGPoint(x: 0, y: 0), gridSize: 3) == nil)
    }

    @Test("Multi-monitor sampling bridges pixels across display seams")
    func multiMonitorSeamSampling() throws {
        let leftColor = EyeDropperColor(red: 250, green: 50, blue: 50)
        let rightColor = EyeDropperColor(red: 40, green: 120, blue: 250)
        let leftSurface = try #require(EyeDropperSurface(
            cgImage: try makeSRGBImage(rows: [[leftColor, leftColor], [leftColor, leftColor]]),
            screenRect: CGRect(x: 0, y: 0, width: 2, height: 2)
        ))
        let rightSurface = try #require(EyeDropperSurface(
            cgImage: try makeSRGBImage(rows: [[rightColor, rightColor], [rightColor, rightColor]]),
            screenRect: CGRect(x: 2, y: 0, width: 2, height: 2)
        ))

        // Sample right edge of left display (pixel x=1, y=0) with right display as sibling.
        let sample = try #require(leftSurface.sample(
            at: CGPoint(x: 1.5, y: 1.5),
            gridSize: 3,
            fallbackSurfaces: [rightSurface]
        ))
        #expect(sample.center == leftColor)
        // Right neighbor (dx=+1, dy=0 -> index 5) comes from the adjacent right display!
        #expect(sample.pixels[5] == rightColor)
    }

    @Test("Loupe layout keeps lens centered on cursor and adapts pill near screen edges")
    func loupeLayoutAndEdgeFlipping() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

        // Center of screen: pill below, no horizontal offset, lens centered on cursor.
        let centerCursor = CGPoint(x: 720, y: 450)
        let centerLayout = EyeDropperLoupeLayout.compute(cursor: centerCursor, screenFrame: screen)
        #expect(centerLayout.pillPlacement == .below)
        #expect(centerLayout.pillOffsetX == 0)
        #expect(centerLayout.panelOrigin.x + centerLayout.panelSize.width / 2 == centerCursor.x)
        #expect(centerLayout.panelOrigin.y + centerLayout.panelSize.height / 2 == centerCursor.y)

        // Near bottom edge: pill flips above, lens still centered on cursor.
        let bottomCursor = CGPoint(x: 720, y: 20)
        let bottomLayout = EyeDropperLoupeLayout.compute(cursor: bottomCursor, screenFrame: screen)
        #expect(bottomLayout.pillPlacement == .above)
        #expect(bottomLayout.panelOrigin.y + bottomLayout.panelSize.height / 2 == bottomCursor.y)

        // Near left edge: pill shifts right to stay on screen.
        let leftLayout = EyeDropperLoupeLayout.compute(cursor: CGPoint(x: 10, y: 450), screenFrame: screen)
        #expect(leftLayout.pillOffsetX > 0)
        #expect(leftLayout.pillOffsetX <= EyeDropperLoupeLayout.maxPillHorizontalShift)

        // Near right edge: pill shifts left to stay on screen.
        let rightLayout = EyeDropperLoupeLayout.compute(cursor: CGPoint(x: 1430, y: 450), screenFrame: screen)
        #expect(rightLayout.pillOffsetX < 0)
        #expect(rightLayout.pillOffsetX >= -EyeDropperLoupeLayout.maxPillHorizontalShift)
    }

    @Test("Zoom levels step monotonically and clamp at ends")
    func zoomLevelStepping() {
        #expect(EyeDropperLoupeLayout.nextZoomLevel(from: 11, zoomIn: true) == 9)
        #expect(EyeDropperLoupeLayout.nextZoomLevel(from: 11, zoomIn: false) == 13)
        #expect(EyeDropperLoupeLayout.nextZoomLevel(from: 7, zoomIn: true) == 7)
        #expect(EyeDropperLoupeLayout.nextZoomLevel(from: 19, zoomIn: false) == 19)
    }

    private func makeSRGBImage(rows: [[EyeDropperColor]]) throws -> CGImage {
        let height = rows.count
        let width = try #require(rows.first?.count)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = rows[y][x]
                let offset = (y * width + x) * 4
                bytes[offset] = c.red
                bytes[offset + 1] = c.green
                bytes[offset + 2] = c.blue
                bytes[offset + 3] = 255
            }
        }
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }
}
