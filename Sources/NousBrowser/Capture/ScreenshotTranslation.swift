import CoreGraphics
import Foundation
import NaturalLanguage
@preconcurrency import Translation

// MARK: - Translation Overlay Models

/// Visual presentation of translated text over a screenshot.
nonisolated enum TranslationOverlayStyle: String, Codable, CaseIterable, Equatable, Sendable, Identifiable {
    /// Covers original text with its sampled background and draws translated text in place.
    case inPlace
    /// Keeps original text visible and attaches a frosted bilingual annotation callout card.
    case callout

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inPlace: L10n.string("Replace")
        case .callout: L10n.string("Annotate")
        }
    }
}

/// One translated text block stored non-destructively inside a ScreenshotDocument.
nonisolated struct ScreenshotTranslationOverlay: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    /// Original-image pixel coordinates, top-left origin.
    var rect: CGRect
    var sourceText: String
    var translatedText: String
    var background: RGBA
    var ink: RGBA
    var lineCount: Int

    init(id: UUID = UUID(), rect: CGRect, sourceText: String, translatedText: String,
         background: RGBA, ink: RGBA, lineCount: Int = 1) {
        self.id = id
        self.rect = rect
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.background = background
        self.ink = ink
        self.lineCount = max(1, lineCount)
    }
}

/// A selectable target language for on-device screenshot translation.
nonisolated struct TranslationTargetOption: Identifiable, Equatable, Hashable, Sendable {
    /// Empty string means Automatic (translates foreign text into primary language,
    /// or primary-language text into secondary preferred language).
    let identifier: String
    let displayName: String

    var id: String { identifier }
    var language: Locale.Language? {
        identifier.isEmpty ? nil : Locale.Language(identifier: identifier)
    }

    static let automatic = TranslationTargetOption(identifier: "", displayName: L10n.string("Automatic"))

    static let presets: [TranslationTargetOption] = [
        .automatic,
        TranslationTargetOption(identifier: "zh-Hans", displayName: "简体中文"),
        TranslationTargetOption(identifier: "zh-Hant", displayName: "繁體中文"),
        TranslationTargetOption(identifier: "en", displayName: "English"),
        TranslationTargetOption(identifier: "ja", displayName: "日本語"),
        TranslationTargetOption(identifier: "ko", displayName: "한국어"),
        TranslationTargetOption(identifier: "fr", displayName: "Français"),
        TranslationTargetOption(identifier: "de", displayName: "Deutsch"),
        TranslationTargetOption(identifier: "es", displayName: "Español"),
        TranslationTargetOption(identifier: "it", displayName: "Italiano"),
        TranslationTargetOption(identifier: "pt-BR", displayName: "Português"),
        TranslationTargetOption(identifier: "ru", displayName: "Русский"),
    ]
}

/// Identifies an uninstalled language pair that Apple's Translation framework can download via SwiftUI.
nonisolated struct TranslationDownloadPair: Equatable, Sendable {
    let source: Locale.Language
    let target: Locale.Language
}

// MARK: - On-Device Translator (Apple Translation + NaturalLanguage + ICU)

actor ScreenshotTranslator {
    struct Outcome: Sendable {
        var target: Locale.Language
        var translatedByBlockID: [UUID: String] = [:]
        var needsDownload: [TranslationDownloadPair] = []
        var unsupportedCount: Int = 0
    }

    private var sessions: [String: TranslationSession] = [:]

    func translate(
        blocks: [TextParagraphBlock],
        to requestedTarget: Locale.Language?,
        preferred: [Locale.Language] = ScreenshotTranslator.preferredLanguages()
    ) async throws -> Outcome {
        let candidates = blocks.filter { !Self.shouldSkipTranslation($0.text) }
        let detected: [(block: TextParagraphBlock, language: Locale.Language?)] = candidates.map { block in
            (block, Self.detectLanguage(of: block.text, preferred: preferred))
        }
        let target = requestedTarget ?? Self.chooseAutomaticTarget(
            for: detected.map { ($0.block.text, $0.language) },
            preferred: preferred
        )
        var outcome = Outcome(target: target)

        // Group blocks by source language; convert Simplified <-> Traditional Chinese immediately via ICU.
        var grouped: [Locale.Language: [TextParagraphBlock]] = [:]
        var languageOrder: [Locale.Language] = []
        for entry in detected {
            guard let source = entry.language else { continue }
            if Self.isSameLanguage(source, target) { continue }
            if let transform = Self.chineseScriptTransform(from: source, to: target) {
                outcome.translatedByBlockID[entry.block.id] = entry.block.text
                    .applyingTransform(transform, reverse: false) ?? entry.block.text
                continue
            }
            if grouped[source] == nil { languageOrder.append(source) }
            grouped[source, default: []].append(entry.block)
        }

        let availability = LanguageAvailability()
        for source in languageOrder {
            guard let group = grouped[source], !group.isEmpty else { continue }
            let status = await availability.status(from: source, to: target)
            switch status {
            case .installed:
                let session = cachedSession(from: source, to: target)
                let results = try await translateGroup(group, using: session, target: target)
                for (id, text) in results { outcome.translatedByBlockID[id] = text }
            case .supported:
                outcome.needsDownload.append(TranslationDownloadPair(source: source, target: target))
            case .unsupported:
                outcome.unsupportedCount += group.count
            @unknown default:
                outcome.unsupportedCount += group.count
            }
        }
        return outcome
    }

    /// Runs translation directly with an already-prepared SwiftUI `.translationTask` session.
    func translate(
        blocks: [TextParagraphBlock],
        using session: TranslationSession,
        source: Locale.Language,
        target: Locale.Language,
        preferred: [Locale.Language] = ScreenshotTranslator.preferredLanguages()
    ) async throws -> [UUID: String] {
        let matching = blocks.filter { block in
            guard !Self.shouldSkipTranslation(block.text),
                  let detected = Self.detectLanguage(of: block.text, preferred: preferred) else { return false }
            return Self.isSameLanguage(detected, source)
        }
        guard !matching.isEmpty else { return [:] }
        return try await translateGroup(matching, using: session, target: target)
    }

    private func cachedSession(from source: Locale.Language, to target: Locale.Language) -> TranslationSession {
        let key = "\(source.maximalIdentifier)->\(target.maximalIdentifier)"
        if let existing = sessions[key] { return existing }
        let created = TranslationSession(installedSource: source, target: target)
        sessions[key] = created
        return created
    }

    private func translateGroup(
        _ group: [TextParagraphBlock],
        using session: TranslationSession,
        target: Locale.Language
    ) async throws -> [UUID: String] {
        // Batch short UI labels separated by " | " so isolated words retain UI context.
        var shortBlocks: [TextParagraphBlock] = []
        var longBlocks: [TextParagraphBlock] = []
        for block in group {
            let wordCount = block.text.split(whereSeparator: \.isWhitespace).count
            if wordCount <= 5 && block.text.count <= 32 && !block.text.contains("|") && block.lineCount == 1 {
                shortBlocks.append(block)
            } else {
                longBlocks.append(block)
            }
        }

        var batches: [[TextParagraphBlock]] = []
        if shortBlocks.count >= 2 {
            var index = 0
            while index < shortBlocks.count {
                let end = min(index + 16, shortBlocks.count)
                batches.append(Array(shortBlocks[index..<end]))
                index = end
            }
        } else {
            longBlocks.append(contentsOf: shortBlocks)
        }

        var requests: [TranslationSession.Request] = longBlocks.enumerated().map { idx, block in
            TranslationSession.Request(sourceText: block.text, clientIdentifier: "s\(idx)")
        }
        requests += batches.enumerated().map { idx, batch in
            TranslationSession.Request(
                sourceText: batch.map(\.text).joined(separator: " | "),
                clientIdentifier: "b\(idx)"
            )
        }

        var output: [UUID: String] = [:]
        var fallbackBlocks: [TextParagraphBlock] = []
        for response in try await session.translations(from: requests) {
            guard let id = response.clientIdentifier, let index = Int(id.dropFirst()) else { continue }
            if id.hasPrefix("s"), longBlocks.indices.contains(index) {
                output[longBlocks[index].id] = Self.cleanTranslation(response.targetText, target: target)
            } else if id.hasPrefix("b"), batches.indices.contains(index) {
                let members = batches[index]
                let pieces = response.targetText
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if pieces.count == members.count && !pieces.contains(where: \.isEmpty) {
                    for (member, piece) in zip(members, pieces) {
                        output[member.id] = Self.cleanTranslation(piece, target: target)
                    }
                } else {
                    fallbackBlocks.append(contentsOf: members)
                }
            }
        }

        if !fallbackBlocks.isEmpty {
            let retryRequests = fallbackBlocks.enumerated().map { idx, block in
                TranslationSession.Request(sourceText: block.text, clientIdentifier: "\(idx)")
            }
            for response in try await session.translations(from: retryRequests) {
                guard let id = response.clientIdentifier, let index = Int(id),
                      fallbackBlocks.indices.contains(index) else { continue }
                output[fallbackBlocks[index].id] = Self.cleanTranslation(response.targetText, target: target)
            }
        }
        return output
    }

    // MARK: - Language Detection & Filtering (Pure Helpers)

    nonisolated static func preferredLanguages() -> [Locale.Language] {
        var result: [Locale.Language] = []
        for raw in Locale.preferredLanguages {
            let lang = normalizeLanguage(Locale.Language(identifier: raw))
            if !result.contains(where: { isSameLanguage($0, lang) }) {
                result.append(lang)
            }
        }
        let defaults = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en")]
        for lang in defaults where !result.contains(where: { isSameLanguage($0, lang) }) {
            result.append(lang)
        }
        return result
    }

    /// Skips pure numbers, bare URLs/paths, timestamps, or code-like tokens so technical text isn't corrupted.
    nonisolated static func shouldSkipTranslation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return true }
        let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return true }

        // Bare URLs, emails, file paths, CLI flags
        let lower = trimmed.lowercased()
        if !trimmed.contains(" ") {
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://")
                || lower.hasPrefix("/") || lower.hasPrefix("~/") || lower.hasPrefix("--")
                || lower.hasPrefix("@") || lower.hasPrefix("#") {
                return true
            }
            if trimmed.contains("@") && trimmed.contains(".") { return true }
            // Single token with file extension or snake_case / camelCase code symbol
            if trimmed.contains("_") || trimmed.contains("::") || trimmed.contains("->") { return true }
        }
        // Short numeric + unit labels such as "12.4 GB", "100%", "v1.4.25", "2026-11-28"
        if trimmed.range(of: #"^[vV]?\d[\d.,:\-/]*\s*(%|px|pt|em|rem|ms|s|kb|mb|gb|tb|hz|khz|mhz|ghz)?$"#,
                         options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return false
    }

    /// Detects the primary language of `text` using Unicode scripts first, then NaturalLanguage.
    nonisolated static func detectLanguage(of text: String, preferred: [Locale.Language]) -> Locale.Language? {
        var han = 0, kana = 0, hangul = 0, latin = 0, cyrillic = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF: kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF: hangul += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: han += 1
            case 0x0400...0x04FF: cyrillic += 1
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F: latin += 1
            default: break
            }
        }
        if kana >= 2 || (kana >= 1 && kana + han >= latin) {
            return Locale.Language(identifier: "ja")
        }
        if hangul >= 2 || (hangul >= 1 && hangul >= latin) {
            return Locale.Language(identifier: "ko")
        }
        if han >= 2 || (han >= 1 && han * 2 >= latin) {
            let prefersTraditional = preferred.first {
                $0.languageCode == .chinese
            }?.script == .hanTraditional
            return detectChineseVariant(text, preferTraditional: prefersTraditional)
        }
        if cyrillic >= 3 && cyrillic > latin {
            return Locale.Language(identifier: "ru")
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        if let best = hypotheses.max(by: { $0.value < $1.value }), best.value >= 0.65 {
            return normalizeLanguage(Locale.Language(identifier: best.key.rawValue))
        }
        if latin >= 2 {
            // Short English/Latin UI labels frequently misclassify in NLLanguageRecognizer;
            // default to the user's preferred Latin language (or English).
            let preferredLatin = preferred.first { lang in
                guard let code = lang.languageCode?.identifier else { return false }
                return ["en", "fr", "de", "es", "it", "pt"].contains(code)
            }
            return preferredLatin ?? Locale.Language(identifier: "en")
        }
        return nil
    }

    nonisolated static func chooseAutomaticTarget(
        for detected: [(text: String, language: Locale.Language?)],
        preferred: [Locale.Language]
    ) -> Locale.Language {
        let valid = detected.compactMap { item -> (weight: Int, lang: Locale.Language)? in
            guard let lang = item.language else { return nil }
            return (max(1, item.text.count), lang)
        }
        let primary = preferred.first ?? Locale.Language(identifier: "zh-Hans")
        let secondary = preferred.dropFirst().first { !isSameLanguage($0, primary) }
            ?? (primary.languageCode == .chinese ? Locale.Language(identifier: "en") : Locale.Language(identifier: "zh-Hans"))
        guard !valid.isEmpty else { return primary }

        let totalWeight = valid.reduce(0) { $0 + $1.weight }
        let primaryWeight = valid.filter { isSameLanguage($0.lang, primary) }.reduce(0) { $0 + $1.weight }
        return Double(primaryWeight) / Double(max(1, totalWeight)) >= 0.55 ? secondary : primary
    }

    nonisolated static func isSameLanguage(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        let na = normalizeLanguage(a)
        let nb = normalizeLanguage(b)
        if na.languageCode == .chinese && nb.languageCode == .chinese {
            return na.script == nb.script
        }
        return na.languageCode == nb.languageCode
    }

    nonisolated static func chineseScriptTransform(from source: Locale.Language, to target: Locale.Language) -> StringTransform? {
        let s = normalizeLanguage(source)
        let t = normalizeLanguage(target)
        guard s.languageCode == .chinese, t.languageCode == .chinese, s.script != t.script else { return nil }
        if s.script == .hanSimplified && t.script == .hanTraditional {
            return StringTransform("Hans-Hant")
        }
        if s.script == .hanTraditional && t.script == .hanSimplified {
            return StringTransform("Hant-Hans")
        }
        return nil
    }

    nonisolated static func normalizeLanguage(_ language: Locale.Language) -> Locale.Language {
        if language.languageCode == .chinese {
            if language.script == .hanTraditional
                || language.region?.identifier == "TW"
                || language.region?.identifier == "HK"
                || language.region?.identifier == "MO" {
                return Locale.Language(identifier: "zh-Hant")
            }
            return Locale.Language(identifier: "zh-Hans")
        }
        if let code = language.languageCode?.identifier {
            return Locale.Language(identifier: code)
        }
        return language
    }

    private nonisolated static func detectChineseVariant(_ text: String, preferTraditional: Bool) -> Locale.Language {
        let toSimplified = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        let toTraditional = text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
        let diffFromSimplified = zip(text, toSimplified).filter { $0 != $1 }.count
        let diffFromTraditional = zip(text, toTraditional).filter { $0 != $1 }.count
        if diffFromSimplified > diffFromTraditional { return Locale.Language(identifier: "zh-Hant") }
        if diffFromTraditional > diffFromSimplified { return Locale.Language(identifier: "zh-Hans") }
        return Locale.Language(identifier: preferTraditional ? "zh-Hant" : "zh-Hans")
    }

    private nonisolated static func cleanTranslation(_ text: String, target: Locale.Language) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.languageCode == .chinese || target.languageCode == .japanese {
            // Remove stray ASCII spaces Apple's model sometimes inserts after CJK punctuation.
            cleaned = cleaned.replacingOccurrences(of: "。 ", with: "。")
                .replacingOccurrences(of: "， ", with: "，")
                .replacingOccurrences(of: "！ ", with: "！")
                .replacingOccurrences(of: "？ ", with: "？")
                .replacingOccurrences(of: "： ", with: "：")
        }
        return cleaned
    }
}
