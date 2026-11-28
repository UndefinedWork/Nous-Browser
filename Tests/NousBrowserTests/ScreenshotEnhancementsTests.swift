import AppKit
import CoreGraphics
import CoreText
import Foundation
import SwiftUI
import Testing
@testable import NousBrowser

@Suite("Screenshot Enhancements (OCR, Spotlight, Translation)")
struct ScreenshotEnhancementsTests {

    // MARK: - Codable Compatibility & Models

    @Test("Legacy ScreenshotDocument JSON decodes with sensible defaults")
    func legacyDocumentDecoding() throws {
        let legacyJSON = """
        {
          "style": {
            "background": { "none": {} },
            "padding": 0,
            "cornerRadius": 0,
            "shadow": 0,
            "aspect": "auto"
          },
          "annotations": [
            {
              "kind": "rectangle",
              "points": [[10, 20], [110, 120]],
              "color": { "r": 1, "g": 0, "b": 0, "a": 1 },
              "width": 3,
              "text": "",
              "number": 0,
              "filled": false
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(ScreenshotDocument.self, from: Data(legacyJSON.utf8))
        #expect(decoded.annotations.count == 1)
        #expect(decoded.annotations[0].kind == .rectangle)
        #expect(decoded.annotations[0].dimming == nil)
        #expect(decoded.annotations[0].effectiveDimming == 0.55)
        #expect(decoded.translations.isEmpty)
        #expect(decoded.translationStyle == .inPlace)
        #expect(decoded.showsTranslations == true)
        #expect(!decoded.hasVisibleTranslations)
    }

    @Test("ScreenshotDocument round-trips spotlight and translation overlays")
    func modernDocumentRoundTrip() throws {
        let spotlight = ScreenshotAnnotation(
            kind: .spotlight,
            points: [CGPoint(x: 40, y: 50), CGPoint(x: 240, y: 180)],
            color: RGBA(hex: 0xFFFFFF),
            width: 3.5,
            dimming: 0.75
        )
        let overlay = ScreenshotTranslationOverlay(
            rect: CGRect(x: 20, y: 30, width: 160, height: 28),
            sourceText: "Hello World",
            translatedText: "你好世界",
            background: RGBA(1, 1, 1),
            ink: RGBA(0.1, 0.1, 0.1),
            lineCount: 1
        )
        let original = ScreenshotDocument(
            annotations: [spotlight],
            translations: [overlay],
            translationStyle: .callout,
            showsTranslations: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScreenshotDocument.self, from: data)
        #expect(decoded == original)
        #expect(decoded.annotations[0].effectiveDimming == 0.75)
        #expect(decoded.hasVisibleTranslations)
    }

    @Test("Spotlight dimming clamps to supported bounds")
    func spotlightDimmingClamping() {
        let low = ScreenshotAnnotation(kind: .spotlight, points: [.zero, CGPoint(x: 50, y: 50)], color: RGBA(hex: 0xFFFFFF), width: 3, dimming: 0.05)
        let high = ScreenshotAnnotation(kind: .spotlight, points: [.zero, CGPoint(x: 50, y: 50)], color: RGBA(hex: 0xFFFFFF), width: 3, dimming: 0.99)
        #expect(low.effectiveDimming == 0.2)
        #expect(high.effectiveDimming == 0.85)
    }

    @Test("ScreenshotTool shortcuts are unique across all tools")
    func uniqueToolShortcuts() {
        let shortcuts = ScreenshotTool.allCases.map { String($0.shortcut.character) }
        #expect(Set(shortcuts).count == shortcuts.count)
        #expect(ScreenshotTool.spotlight.shortcut == "s")
        #expect(ScreenshotTool.ocr.shortcut == "x")
    }

    // MARK: - Pixel Analysis (Dark Ground & Background/Ink Sampling)

    @Test("isDarkGround distinguishes dark and light screenshot regions")
    func darkGroundDetection() throws {
        let darkImage = try makeSolidImage(width: 80, height: 80, r: 22, g: 24, b: 28)
        let lightImage = try makeSolidImage(width: 80, height: 80, r: 245, g: 246, b: 248)
        let rect = CGRect(x: 10, y: 10, width: 60, height: 60)

        #expect(ScreenshotPixelAnalysis.isDarkGround(in: darkImage, rect: rect) == true)
        #expect(ScreenshotPixelAnalysis.isDarkGround(in: lightImage, rect: rect) == false)
    }

    @Test("sampleBackgroundAndInk recovers border background and contrasting ink")
    func backgroundAndInkSampling() throws {
        // White background with dark blue text box in center
        let lightCard = try makeTextBannerImage(
            text: "Hello",
            width: 320,
            height: 100,
            background: NSColor(srgbRed: 0.96, green: 0.96, blue: 0.98, alpha: 1),
            foreground: NSColor(srgbRed: 0.08, green: 0.12, blue: 0.20, alpha: 1)
        )
        let lightSample = ScreenshotPixelAnalysis.sampleBackgroundAndInk(
            in: lightCard,
            rect: CGRect(x: 30, y: 20, width: 200, height: 60)
        )
        #expect(lightSample.background.r > 0.85 && lightSample.background.g > 0.85 && lightSample.background.b > 0.85)
        #expect(lightSample.ink.r < 0.35 && lightSample.ink.g < 0.35)

        // Dark background with bright white text
        let darkCard = try makeTextBannerImage(
            text: "Hello",
            width: 320,
            height: 100,
            background: NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1),
            foreground: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.99, alpha: 1)
        )
        let darkSample = ScreenshotPixelAnalysis.sampleBackgroundAndInk(
            in: darkCard,
            rect: CGRect(x: 30, y: 20, width: 200, height: 60)
        )
        #expect(darkSample.background.r < 0.25 && darkSample.background.g < 0.25)
        #expect(darkSample.ink.r > 0.75 && darkSample.ink.g > 0.75)
    }

    // MARK: - OCR Reading Order, Assembly, Paragraph Grouping & End-to-End Vision

    @Test("Reading order sorts rows top-to-bottom and columns left-to-right")
    func readingOrderAndTextAssembly() {
        let lines = [
            RecognizedTextLine(text: "Second row", rect: CGRect(x: 20, y: 80, width: 120, height: 20)),
            RecognizedTextLine(text: "Right col", rect: CGRect(x: 200, y: 22, width: 100, height: 20)),
            RecognizedTextLine(text: "Left col", rect: CGRect(x: 20, y: 20, width: 100, height: 20)),
            RecognizedTextLine(text: "Separate paragraph", rect: CGRect(x: 20, y: 150, width: 180, height: 20)),
        ]
        let sorted = ScreenshotTextRecognizer.sortReadingOrder(lines)
        #expect(sorted.map(\.text) == ["Left col", "Right col", "Second row", "Separate paragraph"])

        let assembled = ScreenshotTextRecognizer.assembleText(from: lines)
        #expect(assembled == "Left col  Right col\n\nSecond row\n\nSeparate paragraph")
    }

    @Test("groupParagraphs joins wrapped prose, repairs English hyphens, keeps CJK seamless, and splits bullets")
    func paragraphGroupingRules() {
        let lines = [
            RecognizedTextLine(text: "This is a hyphen-", rect: CGRect(x: 20, y: 20, width: 220, height: 20)),
            RecognizedTextLine(text: "ated paragraph line.", rect: CGRect(x: 20, y: 46, width: 210, height: 20)),
            RecognizedTextLine(text: "• First bullet", rect: CGRect(x: 20, y: 74, width: 150, height: 20)),
            RecognizedTextLine(text: "• Second bullet", rect: CGRect(x: 20, y: 100, width: 160, height: 20)),
            RecognizedTextLine(text: "这是第一行中文", rect: CGRect(x: 20, y: 180, width: 180, height: 22)),
            RecognizedTextLine(text: "紧接着第二行。", rect: CGRect(x: 20, y: 208, width: 170, height: 22)),
        ]
        let blocks = ScreenshotTextRecognizer.groupParagraphs(from: lines)
        #expect(blocks.count == 4)
        #expect(blocks[0].text == "This is a hyphenated paragraph line.")
        #expect(blocks[0].lineCount == 2)
        #expect(blocks[1].text == "• First bullet")
        #expect(blocks[2].text == "• Second bullet")
        #expect(blocks[3].text == "这是第一行中文紧接着第二行。")
        #expect(blocks[3].lineCount == 2)
    }

    @Test("On-device Apple Vision OCR recognizes English and Chinese text from rendered CGImage")
    func endToEndVisionOCR() async throws {
        let image = try makeMultiLineTextImage(lines: [
            "Nous Browser Studio",
            "本地文字识别测试",
        ])
        let recognized = try await ScreenshotTextRecognizer.recognize(in: image)
        let joined = ScreenshotTextRecognizer.assembleText(from: recognized)
        #expect(!recognized.isEmpty)
        #expect(joined.contains("Nous"))
        #expect(joined.contains("Browser"))
        #expect(joined.contains("本地") || joined.contains("文字"))
    }

    // MARK: - Translation Helpers (Skip Filter, Language Detection, Auto Target, ICU Hans<->Hant)

    @Test("shouldSkipTranslation skips URLs, paths, code symbols, and numeric metrics while keeping prose")
    func translationSkipFilter() {
        #expect(ScreenshotTranslator.shouldSkipTranslation("https://github.com/UndefinedWork/Nous-Browser"))
        #expect(ScreenshotTranslator.shouldSkipTranslation("/Users/cellier/Documents"))
        #expect(ScreenshotTranslator.shouldSkipTranslation("screenshot_editor_model"))
        #expect(ScreenshotTranslator.shouldSkipTranslation("v1.4.25"))
        #expect(ScreenshotTranslator.shouldSkipTranslation("12.4 GB"))
        #expect(ScreenshotTranslator.shouldSkipTranslation("100%"))
        #expect(ScreenshotTranslator.shouldSkipTranslation("A"))

        #expect(!ScreenshotTranslator.shouldSkipTranslation("Save password for example.com?"))
        #expect(!ScreenshotTranslator.shouldSkipTranslation("Settings"))
        #expect(!ScreenshotTranslator.shouldSkipTranslation("本地截图翻译"))
    }

    @Test("detectLanguage identifies Chinese variants, Japanese, Korean, and English")
    func languageDetection() {
        let preferred = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en")]

        let zhHans = ScreenshotTranslator.detectLanguage(of: "支持本地文字识别和截图翻译", preferred: preferred)
        #expect(zhHans?.languageCode == .chinese)
        #expect(zhHans?.script == .hanSimplified)

        let zhHant = ScreenshotTranslator.detectLanguage(of: "支援本機文字辨識與截圖翻譯", preferred: preferred)
        #expect(zhHant?.languageCode == .chinese)
        #expect(zhHant?.script == .hanTraditional)

        let ja = ScreenshotTranslator.detectLanguage(of: "スクリーンショットのテキストを翻訳", preferred: preferred)
        #expect(ja?.languageCode == .japanese)

        let ko = ScreenshotTranslator.detectLanguage(of: "스크린샷 텍스트를 번역합니다", preferred: preferred)
        #expect(ko?.languageCode == .korean)

        let en = ScreenshotTranslator.detectLanguage(of: "Capture and translate screenshots locally on your Mac.", preferred: preferred)
        #expect(en?.languageCode == .english)
    }

    @Test("chooseAutomaticTarget translates foreign text to primary language and primary text to secondary")
    func automaticTargetSelection() {
        let preferred = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en")]

        // English screenshot -> translates to primary (zh-Hans)
        let targetForEnglish = ScreenshotTranslator.chooseAutomaticTarget(
            for: [("Welcome to Nous Browser", Locale.Language(identifier: "en"))],
            preferred: preferred
        )
        #expect(ScreenshotTranslator.isSameLanguage(targetForEnglish, Locale.Language(identifier: "zh-Hans")))

        // Chinese screenshot -> translates to secondary (en)
        let targetForChinese = ScreenshotTranslator.chooseAutomaticTarget(
            for: [("欢迎使用本地浏览器截图工具", Locale.Language(identifier: "zh-Hans"))],
            preferred: preferred
        )
        #expect(ScreenshotTranslator.isSameLanguage(targetForChinese, Locale.Language(identifier: "en")))
    }

    @Test("ICU converts Simplified and Traditional Chinese immediately without downloading language packs")
    func chineseScriptConversionEndToEnd() async throws {
        let block = TextParagraphBlock(
            id: UUID(),
            lines: [RecognizedTextLine(text: "浏览器截图翻译", rect: CGRect(x: 10, y: 10, width: 160, height: 24))],
            text: "浏览器截图翻译",
            rect: CGRect(x: 10, y: 10, width: 160, height: 24)
        )
        let translator = ScreenshotTranslator()
        let outcome = try await translator.translate(
            blocks: [block],
            to: Locale.Language(identifier: "zh-Hant"),
            preferred: [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en")]
        )
        #expect(outcome.needsDownload.isEmpty)
        let converted = try #require(outcome.translatedByBlockID[block.id])
        #expect(converted == "瀏覽器截圖翻譯")
    }

    // MARK: - Rendered Overlay Placement Verification

    @Test("TranslationOverlayLayer positions in-place patch at exact image coordinates, not centered")
    @MainActor
    func translationOverlayAlignment() throws {
        let imageSize = CGSize(width: 400, height: 300)
        // Put a bright green patch in the top-left corner (x: 10..110, y: 10..50).
        let overlay = ScreenshotTranslationOverlay(
            rect: CGRect(x: 16, y: 16, width: 90, height: 30),
            sourceText: "Top Left",
            translatedText: "左上",
            background: RGBA(0.1, 0.9, 0.2),
            ink: RGBA(0.0, 0.0, 0.0),
            lineCount: 1
        )
        let view = ZStack(alignment: .topLeading) {
            Color.white
            TranslationOverlayLayer(overlays: [overlay], style: .inPlace, imageSize: imageSize, unit: 1)
        }
        .frame(width: imageSize.width, height: imageSize.height, alignment: .topLeading)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let cgImage = try #require(renderer.cgImage)

        // Pixel inside the top-left overlay patch should be bright green (g > 180, r < 80).
        let patchPixel = try pixelRGB(in: cgImage, x: 20, y: 20)
        #expect(patchPixel.g > 180 && patchPixel.r < 90)

        // Pixel at the center of the image (200, 150) must still be untouched white!
        let centerPixel = try pixelRGB(in: cgImage, x: 200, y: 150)
        #expect(centerPixel.r > 240 && centerPixel.g > 240 && centerPixel.b > 240)
    }

    // MARK: - Synthetic Image Helpers

    private func makeSolidImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = 255
        }
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    private func makeTextBannerImage(text: String, width: Int, height: Int, background: NSColor, foreground: NSColor) throws -> CGImage {
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 40, nil)
        let attr = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: foreground,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 44, y: 34)
        CTLineDraw(line, ctx)
        return try #require(ctx.makeImage())
    }

    private func makeMultiLineTextImage(lines: [String]) throws -> CGImage {
        let width = 720
        let height = 240
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = NSFont.systemFont(ofSize: 42, weight: .semibold)
        for (idx, text) in lines.enumerated() {
            let attr = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: NSColor.black,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 48, y: CGFloat(height - 84 - idx * 80))
            CTLineDraw(line, ctx)
        }
        return try #require(ctx.makeImage())
    }

    private func pixelRGB(in image: CGImage, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let w = image.width, h = image.height
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                  ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        #expect(ok)
        let offset = (y * w + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }
}
