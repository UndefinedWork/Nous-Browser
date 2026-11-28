import CoreGraphics
import Foundation
import Vision

// MARK: - Recognized Text Models

/// One line of text detected in a screenshot, in original-image pixel coordinates (top-left origin).
nonisolated struct RecognizedTextLine: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var text: String
    /// Bounding box in original-image pixels, top-left origin.
    var rect: CGRect
    var confidence: Float

    init(id: UUID = UUID(), text: String, rect: CGRect, confidence: Float = 1) {
        self.id = id
        self.text = text
        self.rect = rect
        self.confidence = confidence
    }
}

/// A logical paragraph or UI text block assembled from one or more adjacent lines.
nonisolated struct TextParagraphBlock: Identifiable, Equatable, Sendable {
    var id: UUID
    var lines: [RecognizedTextLine]
    var text: String
    var rect: CGRect

    var lineCount: Int { lines.count }
}

// MARK: - Pixel Sampling Helpers (Pure CoreGraphics)

nonisolated enum ScreenshotPixelAnalysis {
    /// Determines whether the dominant ground color inside `rect` is dark (luminance < 0.5).
    /// Uses a coarse histogram so text strokes do not outweigh the background they sit on.
    static func isDarkGround(in image: CGImage, rect: CGRect) -> Bool {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rect.standardized.integral.intersection(imageBounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1,
              let cropped = image.cropping(to: clipped) else { return false }

        let sampleW = min(32, max(4, Int(clipped.width)))
        let sampleH = min(32, max(4, Int(clipped.height)))
        var gray = [UInt8](repeating: 255, count: sampleW * sampleH)
        let ok = gray.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: sampleW,
                    height: sampleH,
                    bitsPerComponent: 8,
                    bytesPerRow: sampleW,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))
            return true
        }
        guard ok else { return false }
        var buckets = [Int](repeating: 0, count: 16)
        for value in gray { buckets[Int(value) >> 4] += 1 }
        let dominant = buckets.indices.max { buckets[$0] < buckets[$1] } ?? 15
        return dominant < 8
    }

    /// Samples the median border color around `rect` (for seamless background replacement)
    /// and a high-contrast foreground ink color inside `rect`.
    static func sampleBackgroundAndInk(in image: CGImage, rect: CGRect) -> (background: RGBA, ink: RGBA) {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let box = rect.standardized.integral.intersection(imageBounds)
        guard !box.isNull, box.width >= 2, box.height >= 2 else {
            return (RGBA(1, 1, 1), RGBA(0.11, 0.11, 0.12))
        }

        let pad = max(2, min(8, (min(box.width, box.height) * 0.18).rounded()))
        let expanded = box.insetBy(dx: -pad, dy: -pad).intersection(imageBounds).integral
        guard let cropped = image.cropping(to: expanded),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            return (RGBA(1, 1, 1), RGBA(0.11, 0.11, 0.12))
        }

        let maxDim = 64
        let scale = min(1.0, Double(maxDim) / Double(max(expanded.width, expanded.height)))
        let w = max(4, Int((Double(expanded.width) * scale).rounded()))
        let h = max(4, Int((Double(expanded.height) * scale).rounded()))
        let bytesPerRow = w * 4
        var buffer = [UInt8](repeating: 255, count: bytesPerRow * h)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: sRGB,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                  ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return (RGBA(1, 1, 1), RGBA(0.11, 0.11, 0.12)) }

        var borderR: [UInt8] = [], borderG: [UInt8] = [], borderB: [UInt8] = []
        borderR.reserveCapacity((w + h) * 2)
        borderG.reserveCapacity((w + h) * 2)
        borderB.reserveCapacity((w + h) * 2)

        func pixelAt(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let i = y * bytesPerRow + x * 4
            return (buffer[i], buffer[i + 1], buffer[i + 2])
        }

        for x in 0..<w {
            let top = pixelAt(x, 0)
            borderR.append(top.0); borderG.append(top.1); borderB.append(top.2)
            let bottom = pixelAt(x, h - 1)
            borderR.append(bottom.0); borderG.append(bottom.1); borderB.append(bottom.2)
        }
        if h > 2 {
            for y in 1..<(h - 1) {
                let left = pixelAt(0, y)
                borderR.append(left.0); borderG.append(left.1); borderB.append(left.2)
                let right = pixelAt(w - 1, y)
                borderR.append(right.0); borderG.append(right.1); borderB.append(right.2)
            }
        }

        func median(_ values: [UInt8]) -> Double {
            guard !values.isEmpty else { return 1 }
            let sorted = values.sorted()
            return Double(sorted[sorted.count / 2]) / 255.0
        }

        let bgR = median(borderR)
        let bgG = median(borderG)
        let bgB = median(borderB)
        let background = RGBA(bgR, bgG, bgB)
        let bgLuminance = 0.2126 * bgR + 0.7152 * bgG + 0.0722 * bgB

        // Collect interior pixels that stand out clearly from the sampled background.
        var candidates: [(dist: Double, r: Double, g: Double, b: Double)] = []
        let insetX = max(1, w / 8)
        let insetY = max(1, h / 8)
        for y in insetY..<max(insetY + 1, h - insetY) {
            for x in insetX..<max(insetX + 1, w - insetX) {
                let p = pixelAt(x, y)
                let r = Double(p.0) / 255.0
                let g = Double(p.1) / 255.0
                let b = Double(p.2) / 255.0
                let dist = abs(r - bgR) + abs(g - bgG) + abs(b - bgB)
                if dist > 0.35 {
                    candidates.append((dist, r, g, b))
                }
            }
        }

        if candidates.count >= 4 {
            candidates.sort { $0.dist > $1.dist }
            let topHalf = candidates.prefix(max(2, candidates.count / 2))
            let rs = topHalf.map(\.r).sorted()
            let gs = topHalf.map(\.g).sorted()
            let bs = topHalf.map(\.b).sorted()
            let mid = topHalf.count / 2
            let candidateInk = RGBA(rs[mid], gs[mid], bs[mid])
            let inkLum = 0.2126 * candidateInk.r + 0.7152 * candidateInk.g + 0.0722 * candidateInk.b
            if abs(inkLum - bgLuminance) >= 0.28 {
                return (background, candidateInk)
            }
        }

        let fallbackInk = bgLuminance > 0.5 ? RGBA(0.10, 0.10, 0.12) : RGBA(0.95, 0.95, 0.97)
        return (background, fallbackInk)
    }
}

// MARK: - On-Device Vision OCR

nonisolated enum ScreenshotTextRecognizer {
    /// Recognizes all text lines in `image` on-device via Apple Vision.
    /// Tall screenshots (> 2560 px) are read in overlapping horizontal bands so small text stays crisp.
    static func recognize(in image: CGImage) async throws -> [RecognizedTextLine] {
        try await Task.detached(priority: .userInitiated) {
            try recognizeSync(in: image)
        }.value
    }

    private static func recognizeSync(in image: CGImage) throws -> [RecognizedTextLine] {
        let totalHeight = image.height
        let totalWidth = image.width
        guard totalWidth > 0, totalHeight > 0 else { return [] }

        let bandThreshold = 2560
        let bandHeight = 2048
        let overlap = 256

        let rawLines: [RecognizedTextLine]
        if totalHeight > bandThreshold {
            rawLines = try recognizeInBands(image: image, bandHeight: bandHeight, overlap: overlap)
        } else {
            rawLines = try recognizeRegion(image: image, originY: 0)
        }
        return sortReadingOrder(rawLines)
    }

    private static func recognizeInBands(image: CGImage, bandHeight: Int, overlap: Int) throws -> [RecognizedTextLine] {
        let totalWidth = image.width
        let totalHeight = image.height
        let step = max(1, bandHeight - overlap)
        var starts: [Int] = []
        var y = 0
        while y < totalHeight {
            starts.append(y)
            if y + bandHeight >= totalHeight { break }
            y += step
        }

        var merged: [RecognizedTextLine] = []
        for (index, startY) in starts.enumerated() {
            try Task.checkCancellation()
            let height = min(bandHeight, totalHeight - startY)
            let cropRect = CGRect(x: 0, y: startY, width: totalWidth, height: height)
            guard let slice = image.cropping(to: cropRect) else { continue }
            let bandLines = try recognizeRegion(image: slice, originY: CGFloat(startY))

            // Each band owns its core strip (trimming half the overlap on shared seams)
            // so lines straddling a band edge are kept once from the band that sees them whole.
            let coreTop: CGFloat = index == 0 ? 0 : CGFloat(startY + overlap / 2)
            let coreBottom: CGFloat = index == starts.count - 1
                ? CGFloat(totalHeight)
                : CGFloat(startY + height - overlap / 2)

            for line in bandLines {
                let midY = line.rect.midY
                guard midY >= coreTop && midY <= coreBottom else { continue }
                let duplicate = merged.contains { existing in
                    existing.text == line.text && abs(existing.rect.midY - midY) < max(6, line.rect.height * 0.5)
                        && abs(existing.rect.minX - line.rect.minX) < max(12, line.rect.width * 0.25)
                }
                if !duplicate { merged.append(line) }
            }
        }
        return merged
    }

    private static func recognizeRegion(image: CGImage, originY: CGFloat) throws -> [RecognizedTextLine] {
        let primaryLanguages = preferredRecognitionLanguages()
        let primary = try runVisionPass(image: image, languages: primaryLanguages, originY: originY)

        // If the primary CJK-capable pass found virtually no CJK characters, re-read with
        // the Latin model to preserve exact ASCII punctuation and case (important for UI & code).
        let joined = primary.map(\.text).joined()
        let cjkCount = joined.unicodeScalars.filter(isCJKScalar).count
        let nonSpaceCount = joined.unicodeScalars.filter { !$0.properties.isWhitespace }.count
        if nonSpaceCount > 0, cjkCount <= 2, Double(cjkCount) / Double(nonSpaceCount) < 0.05 {
            let latin = try runVisionPass(image: image, languages: ["en-US"], originY: originY)
            let latinChars = latin.map(\.text).joined().unicodeScalars.filter { !$0.properties.isWhitespace }.count
            if Double(latinChars) >= Double(nonSpaceCount) * 0.8 {
                return latin
            }
        }
        return primary
    }

    private static func preferredRecognitionLanguages() -> [String] {
        var list = ["zh-Hans", "zh-Hant", "en-US"]
        if let first = Locale.preferredLanguages.first?.lowercased() {
            if first.hasPrefix("ko") {
                list = ["ko-KR", "en-US"]
            } else if first.hasPrefix("ja") {
                list = ["ja-JP", "en-US", "zh-Hans"]
            }
        }
        return list
    }

    private static func runVisionPass(image: CGImage, languages: [String], originY: CGFloat) throws -> [RecognizedTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        guard let observations = request.results else { return [] }

        var results: [RecognizedTextLine] = []
        results.reserveCapacity(observations.count)
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let box = observation.boundingBox
            // Vision uses normalized bottom-left origin; convert to top-left pixel coordinates.
            let rect = CGRect(
                x: box.minX * w,
                y: originY + (1.0 - box.maxY) * h,
                width: box.width * w,
                height: box.height * h
            )
            guard rect.width >= 2, rect.height >= 2 else { continue }
            results.append(RecognizedTextLine(text: trimmed, rect: rect, confidence: candidate.confidence))
        }
        return results
    }

    // MARK: - Reading Order, Assembly & Paragraph Grouping

    /// Sorts recognized lines into natural top-to-bottom, left-to-right reading order.
    static func sortReadingOrder(_ lines: [RecognizedTextLine]) -> [RecognizedTextLine] {
        guard lines.count > 1 else { return lines }
        let byTop = lines.sorted { a, b in
            if abs(a.rect.midY - b.rect.midY) <= min(a.rect.height, b.rect.height) * 0.45 {
                return a.rect.minX < b.rect.minX
            }
            return a.rect.midY < b.rect.midY
        }

        // Group into visual rows so items sharing a horizontal baseline read left-to-right.
        var rows: [[RecognizedTextLine]] = []
        for line in byTop {
            if var lastRow = rows.last, let anchor = lastRow.first,
               sharesVisualRow(anchor.rect, line.rect) {
                lastRow.append(line)
                rows[rows.count - 1] = lastRow
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { row in row.sorted { $0.rect.minX < $1.rect.minX } }
    }

    /// Assembles a clean multi-line string from lines, joining same-row items with spaces.
    static func assembleText(from lines: [RecognizedTextLine]) -> String {
        let sorted = sortReadingOrder(lines)
        guard !sorted.isEmpty else { return "" }
        var output = ""
        var previous: RecognizedTextLine?
        for line in sorted {
            if let prev = previous {
                if sharesVisualRow(prev.rect, line.rect) {
                    output += "  "
                } else {
                    let gap = line.rect.minY - prev.rect.maxY
                    let threshold = max(prev.rect.height, line.rect.height) * 1.15
                    output += gap > threshold ? "\n\n" : "\n"
                }
            }
            output += line.text
            previous = line
        }
        return output
    }

    /// Groups visually wrapped lines into coherent paragraph blocks for natural translation.
    static func groupParagraphs(from lines: [RecognizedTextLine]) -> [TextParagraphBlock] {
        let sorted = sortReadingOrder(lines)
        guard !sorted.isEmpty else { return [] }

        var blocks: [[RecognizedTextLine]] = []
        for line in sorted {
            if let blockIndex = findMergeableBlock(for: line, in: blocks) {
                blocks[blockIndex].append(line)
            } else {
                blocks.append([line])
            }
        }

        return blocks.map { group in
            let unionRect = group.dropFirst().reduce(group[0].rect) { $0.union($1.rect) }
            let text = joinWrappedLines(group)
            return TextParagraphBlock(id: group[0].id, lines: group, text: text, rect: unionRect)
        }
    }

    private static func findMergeableBlock(for line: RecognizedTextLine, in blocks: [[RecognizedTextLine]]) -> Int? {
        // Check recent blocks from back to front for a direct vertical continuation.
        for index in blocks.indices.reversed() {
            guard let prev = blocks[index].last else { continue }
            let h1 = prev.rect.height
            let h2 = line.rect.height
            let minH = min(h1, h2)
            let maxH = max(h1, h2)
            guard maxH / max(minH, 1) <= 1.38 else { continue }

            let verticalGap = line.rect.minY - prev.rect.maxY
            guard verticalGap >= -minH * 0.25 && verticalGap <= maxH * 0.72 else { continue }

            // Must align near the same left column (or centered together) and overlap horizontally.
            let leftAligned = abs(line.rect.minX - prev.rect.minX) <= maxH * 1.4
            let centerAligned = abs(line.rect.midX - prev.rect.midX) <= maxH * 1.2
            let horizontalOverlap = min(prev.rect.maxX, line.rect.maxX) - max(prev.rect.minX, line.rect.minX)
            guard (leftAligned || centerAligned), horizontalOverlap > min(prev.rect.width, line.rect.width) * 0.25 else {
                continue
            }

            // Bullet items start their own paragraph block.
            if startsWithBullet(line.text) { continue }
            return index
        }
        return nil
    }

    private static func joinWrappedLines(_ lines: [RecognizedTextLine]) -> String {
        guard let first = lines.first else { return "" }
        var result = first.text
        for line in lines.dropFirst() {
            let trimmed = line.text
            if result.hasSuffix("-"), let lastWordChar = result.dropLast().last, lastWordChar.isASCII && lastWordChar.isLetter {
                result.removeLast()
                result += trimmed
            } else if endsWithCJK(result) && startsWithCJK(trimmed) {
                result += trimmed
            } else {
                result += " " + trimmed
            }
        }
        return result
    }

    private static func sharesVisualRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlapY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let minH = min(a.height, b.height)
        return overlapY > minH * 0.45 && (a.maxX <= b.minX + minH * 0.5 || b.maxX <= a.minX + minH * 0.5)
    }

    private static func startsWithBullet(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return "•·●▪◦◆■▸▹-–—*".contains(first)
    }

    static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, // Hiragana & Katakana
             0x3400...0x4DBF, // CJK Ext A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xAC00...0xD7AF, // Hangul Syllables
             0xF900...0xFAFF: // CJK Compatibility
            return true
        default:
            return false
        }
    }

    private static func endsWithCJK(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.last else { return false }
        return isCJKScalar(scalar)
    }

    private static func startsWithCJK(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        return isCJKScalar(scalar)
    }
}
