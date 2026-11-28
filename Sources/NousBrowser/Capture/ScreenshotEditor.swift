import AppKit
import CoreImage
import SwiftUI
@preconcurrency import Translation
import UniformTypeIdentifiers

// A screenshot editor in a tab: framing (background, padding, corners, shadow,
// aspect), annotations (including region spotlight and dark/light-adaptive
// highlighter), on-device Vision OCR text selection/copy, and on-device
// Translation annotated overlays. Edits are non-destructive and saved beside
// the original.

nonisolated struct ScreenshotAnnotation: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case arrow, line, rectangle, ellipse, highlight, spotlight, pen, text, step, pixelate
    }
    var id = UUID()
    var kind: Kind
    /// Original-image pixel coordinates, top-left origin.
    var points: [CGPoint]
    var color: RGBA
    var width: Double
    var text = ""
    var number = 0
    var filled = false
    /// Dimming opacity outside spotlight regions (0.2...0.85). Nil uses default 0.55.
    var dimming: Double?

    init(id: UUID = UUID(), kind: Kind, points: [CGPoint], color: RGBA, width: Double,
         text: String = "", number: Int = 0, filled: Bool = false, dimming: Double? = nil) {
        self.id = id
        self.kind = kind
        self.points = points
        self.color = color
        self.width = width
        self.text = text
        self.number = number
        self.filled = filled
        self.dimming = dimming
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, points, color, width, text, number, filled, dimming
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(Kind.self, forKey: .kind)
        points = try container.decode([CGPoint].self, forKey: .points)
        color = try container.decode(RGBA.self, forKey: .color)
        width = try container.decode(Double.self, forKey: .width)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        number = try container.decodeIfPresent(Int.self, forKey: .number) ?? 0
        filled = try container.decodeIfPresent(Bool.self, forKey: .filled) ?? false
        dimming = try container.decodeIfPresent(Double.self, forKey: .dimming)
    }

    var rect: CGRect {
        guard let first = points.first else { return .zero }
        let last = points.last ?? first
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
    }

    var fontSize: CGFloat { max(14, width * 6) }
    var stepRadius: CGFloat { max(11, width * 4.2) }
    var effectiveDimming: Double { min(0.85, max(0.2, dimming ?? 0.55)) }

    /// Generous bounds for hit testing and the selection outline.
    var bounds: CGRect {
        switch kind {
        case .text:
            let size = (text.isEmpty ? " " : text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)])
            return CGRect(origin: points.first ?? .zero, size: size).insetBy(dx: -6, dy: -4)
        case .step:
            let center = points.first ?? .zero
            return CGRect(x: center.x - stepRadius, y: center.y - stepRadius, width: stepRadius * 2, height: stepRadius * 2)
        case .pen:
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -width * 2, dy: -width * 2)
        default:
            return rect.insetBy(dx: -max(6, width * 2), dy: -max(6, width * 2))
        }
    }

    func offset(by delta: CGSize) -> ScreenshotAnnotation {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        return copy
    }
}

nonisolated struct ScreenshotDocument: Codable, Equatable, Sendable {
    var style = CaptureStyle()
    /// In original-image pixels.
    var crop: CGRect?
    var annotations: [ScreenshotAnnotation] = []
    /// Non-destructive on-device translated overlays exported with the screenshot.
    var translations: [ScreenshotTranslationOverlay] = []
    var translationStyle: TranslationOverlayStyle = .inPlace
    var showsTranslations: Bool = true

    init(style: CaptureStyle = CaptureStyle(), crop: CGRect? = nil,
         annotations: [ScreenshotAnnotation] = [],
         translations: [ScreenshotTranslationOverlay] = [],
         translationStyle: TranslationOverlayStyle = .inPlace,
         showsTranslations: Bool = true) {
        self.style = style
        self.crop = crop
        self.annotations = annotations
        self.translations = translations
        self.translationStyle = translationStyle
        self.showsTranslations = showsTranslations
    }

    private enum CodingKeys: String, CodingKey {
        case style, crop, annotations, translations, translationStyle, showsTranslations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try container.decodeIfPresent(CaptureStyle.self, forKey: .style) ?? CaptureStyle()
        crop = try container.decodeIfPresent(CGRect.self, forKey: .crop)
        annotations = try container.decodeIfPresent([ScreenshotAnnotation].self, forKey: .annotations) ?? []
        translations = try container.decodeIfPresent([ScreenshotTranslationOverlay].self, forKey: .translations) ?? []
        translationStyle = try container.decodeIfPresent(TranslationOverlayStyle.self, forKey: .translationStyle) ?? .inPlace
        showsTranslations = try container.decodeIfPresent(Bool.self, forKey: .showsTranslations) ?? true
    }

    var hasVisibleTranslations: Bool {
        showsTranslations && !translations.isEmpty
    }
}

enum ScreenshotTool: String, CaseIterable, Identifiable {
    case select, arrow, rectangle, ellipse, line, pen, highlight, spotlight, text, step, pixelate, ocr, crop
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .pen: "scribble"
        case .highlight: "highlighter"
        case .spotlight: "rectangle.center.inset.filled"
        case .text: "textformat"
        case .step: "1.circle"
        case .pixelate: "mosaic"
        case .ocr: "text.viewfinder"
        case .crop: "crop"
        }
    }
    var label: String {
        switch self {
        case .select: L10n.string("Select")
        case .arrow: L10n.string("Arrow")
        case .rectangle: L10n.string("Rectangle")
        case .ellipse: L10n.string("Ellipse")
        case .line: L10n.string("Line")
        case .pen: L10n.string("Pen")
        case .highlight: L10n.string("Highlight")
        case .spotlight: L10n.string("Spotlight")
        case .text: L10n.string("Text")
        case .step: L10n.string("Step")
        case .pixelate: L10n.string("Pixelate")
        case .ocr: L10n.string("Recognize Text")
        case .crop: L10n.string("Crop")
        }
    }
    var shortcut: KeyEquivalent {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "o"
        case .line: "l"
        case .pen: "p"
        case .highlight: "h"
        case .spotlight: "s"
        case .text: "t"
        case .step: "n"
        case .pixelate: "b"
        case .ocr: "x"
        case .crop: "c"
        }
    }
}

/// Undo by whole documents: small and exact. Slider drags coalesce into one step.
@MainActor
@Observable
final class EditorHistory<Document: Equatable> {
    private(set) var undoStack: [Document] = []
    private(set) var redoStack: [Document] = []
    @ObservationIgnored private var lastKey: String?
    @ObservationIgnored private var lastTime: TimeInterval = 0

    func record(_ previous: Document, key: String? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        if let key, key == lastKey, now - lastTime < 0.8 { lastTime = now; return }
        lastKey = key; lastTime = now
        undoStack.append(previous)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo(_ current: Document) -> Document? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current); lastKey = nil
        return previous
    }

    func redo(_ current: Document) -> Document? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current); lastKey = nil
        return next
    }
}

@MainActor
@Observable
final class ScreenshotEditorModel {
    let capture: LibraryCapture
    let image: CGImage
    let pixelated: CGImage
    private(set) var document: ScreenshotDocument
    let history = EditorHistory<ScreenshotDocument>()
    var tool: ScreenshotTool = .arrow
    var color = RGBA(hex: 0xFF3B30)
    var widthLevel = 1
    /// Dimming intensity level for Spotlight: 0 = Light (35%), 1 = Medium (55%), 2 = Dark (75%).
    var spotlightDimmingLevel = 1
    var selectedID: UUID?
    var editingTextID: UUID?
    var draftCrop: CGRect?
    var draft: ScreenshotAnnotation?
    var showsInspector = (NSApp.keyWindow?.frame.width ?? 1200) >= 1000
    var toast: String?

    // On-device OCR state
    private(set) var recognizedLines: [RecognizedTextLine] = []
    private(set) var hasRunOCR = false
    private(set) var isRecognizingText = false
    var selectedTextLineIDs: Set<UUID> = []
    var hoveredTextLineID: UUID?
    var ocrMarqueeRect: CGRect?

    // On-device Translation state
    var targetLanguageID: String = ""
    private(set) var isTranslating = false
    var isPeekingOriginal = false
    var pendingDownloadPair: TranslationDownloadPair?
    var translationTaskConfig: TranslationSession.Configuration?
    var translationStatusMessage: String?

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var ocrTask: Task<[RecognizedTextLine], Never>?
    @ObservationIgnored private var darkGroundCache: [String: Bool] = [:]
    @ObservationIgnored private let translator = ScreenshotTranslator()

    var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
    var contentRect: CGRect { tool == .crop ? CGRect(origin: .zero, size: imageSize) : (document.crop ?? CGRect(origin: .zero, size: imageSize)) }
    var unit: CGFloat { max(1, min(imageSize.width, imageSize.height) / 420) }
    var strokeWidth: Double { [2, 3.5, 6][widthLevel] * unit }
    var spotlightDimming: Double { [0.35, 0.55, 0.75][min(max(0, spotlightDimmingLevel), 2)] }
    var nextStep: Int { (document.annotations.filter { $0.kind == .step }.map(\.number).max() ?? 0) + 1 }

    /// Lines lying inside the active crop region (or whole image if uncropped).
    var visibleRecognizedLines: [RecognizedTextLine] {
        guard let crop = document.crop else { return recognizedLines }
        return recognizedLines.filter { crop.intersects($0.rect) }
    }

    static let palette: [RGBA] = [RGBA(hex: 0xFF3B30), RGBA(hex: 0xFF9500), RGBA(hex: 0xFFCC00), RGBA(hex: 0x34C759),
                                  RGBA(hex: 0x007AFF), RGBA(hex: 0xAF52DE), RGBA(hex: 0xFFFFFF), RGBA(hex: 0x1C1C1E)]

    init?(capture: LibraryCapture) {
        guard let source = CGImageSourceCreateWithURL(capture.url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.capture = capture
        self.image = image
        let input = CIImage(cgImage: image)
        let scale = max(8, Double(min(image.width, image.height)) / 48)
        let output = input.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale]).cropped(to: input.extent)
        pixelated = CIContext().createCGImage(output, from: input.extent) ?? image
        document = LibraryStore.shared.loadEdit(ScreenshotDocument.self, for: capture) ?? ScreenshotDocument()
        if let dimming = document.annotations.last(where: { $0.kind == .spotlight })?.effectiveDimming {
            spotlightDimmingLevel = dimming < 0.45 ? 0 : (dimming > 0.65 ? 2 : 1)
        }
    }

    func isDarkGround(for rect: CGRect) -> Bool {
        let key = "\(Int(rect.minX)):\(Int(rect.minY)):\(Int(rect.width)):\(Int(rect.height))"
        if let cached = darkGroundCache[key] { return cached }
        let dark = ScreenshotPixelAnalysis.isDarkGround(in: image, rect: rect)
        if darkGroundCache.count > 128 { darkGroundCache.removeAll() }
        darkGroundCache[key] = dark
        return dark
    }

    func change(key: String? = nil, _ mutate: (inout ScreenshotDocument) -> Void) {
        var next = document
        mutate(&next)
        guard next != document else { return }
        history.record(document, key: key)
        document = next
        scheduleSave()
    }

    func undo() { if let previous = history.undo(document) { document = previous; selectedID = nil; scheduleSave() } }
    func redo() { if let next = history.redo(document) { document = next; selectedID = nil; scheduleSave() } }

    func styleBinding<T>(_ path: WritableKeyPath<CaptureStyle, T>) -> Binding<T> {
        Binding(get: { self.document.style[keyPath: path] },
                set: { value in self.change(key: "\(path)") { $0.style[keyPath: path] = value } })
    }

    func deleteSelection() {
        guard let selectedID else { return }
        change { $0.annotations.removeAll { $0.id == selectedID } }
        self.selectedID = nil
    }

    func setColor(_ color: RGBA) {
        self.color = color
        if let selectedID { change(key: "color") { doc in
            if let index = doc.annotations.firstIndex(where: { $0.id == selectedID }) { doc.annotations[index].color = color }
        } }
    }

    func setSpotlightDimmingLevel(_ level: Int) {
        spotlightDimmingLevel = min(max(0, level), 2)
        let value = spotlightDimming
        if document.annotations.contains(where: { $0.kind == .spotlight }) {
            change(key: "spotlight-dimming") { doc in
                for index in doc.annotations.indices where doc.annotations[index].kind == .spotlight {
                    doc.annotations[index].dimming = value
                }
            }
        }
    }

    func finishCrop() {
        if let draftCrop, draftCrop.width > 8, draftCrop.height > 8 {
            let full = CGRect(origin: .zero, size: imageSize)
            let crop = draftCrop.intersection(full).integral
            change { $0.crop = crop == full ? nil : crop }
        }
        draftCrop = nil
        tool = .select
    }

    // MARK: On-Device OCR

    @discardableResult
    func ensureTextRecognized() async -> [RecognizedTextLine] {
        if hasRunOCR { return visibleRecognizedLines }
        if let existing = ocrTask {
            _ = await existing.value
            return visibleRecognizedLines
        }
        isRecognizingText = true
        let sourceImage = image
        let task = Task<[RecognizedTextLine], Never> {
            (try? await ScreenshotTextRecognizer.recognize(in: sourceImage)) ?? []
        }
        ocrTask = task
        let lines = await task.value
        ocrTask = nil
        recognizedLines = lines
        hasRunOCR = true
        isRecognizingText = false
        return visibleRecognizedLines
    }

    func copyRecognizedText(selectedOnly: Bool = false) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let lines = await self.ensureTextRecognized()
            let chosen: [RecognizedTextLine]
            if selectedOnly && !self.selectedTextLineIDs.isEmpty {
                chosen = lines.filter { self.selectedTextLineIDs.contains($0.id) }
            } else {
                chosen = lines
            }
            let text = ScreenshotTextRecognizer.assembleText(from: chosen)
            guard !text.isEmpty else {
                self.flash(L10n.string("No Text Found"))
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self.flash(L10n.string("Text Copied"))
        }
    }

    func selectAllRecognizedText() {
        selectedTextLineIDs = Set(visibleRecognizedLines.map(\.id))
    }

    func clearRecognizedTextSelection() {
        selectedTextLineIDs.removeAll()
    }

    // MARK: On-Device Translation

    func translateImage() {
        guard !isTranslating else { return }
        isTranslating = true
        pendingDownloadPair = nil
        translationStatusMessage = nil
        let targetOption = TranslationTargetOption.presets.first { $0.identifier == targetLanguageID }
        let requestedTarget = targetOption?.language

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isTranslating = false }
            let lines = await self.ensureTextRecognized()
            let blocks = ScreenshotTextRecognizer.groupParagraphs(from: lines)
            guard !blocks.isEmpty else {
                self.translationStatusMessage = L10n.string("No text detected in this screenshot.")
                self.flash(L10n.string("No Text Found"))
                return
            }
            do {
                let outcome = try await self.translator.translate(blocks: blocks, to: requestedTarget)
                self.applyTranslationResults(outcome.translatedByBlockID, blocks: blocks)
                if let firstNeeded = outcome.needsDownload.first {
                    self.pendingDownloadPair = firstNeeded
                    if outcome.translatedByBlockID.isEmpty {
                        self.translationStatusMessage = L10n.string("Download the on-device language pack to translate this screenshot.")
                        // Immediately offer macOS's native language pack download sheet.
                        self.startLanguagePackDownload()
                    } else {
                        self.translationStatusMessage = L10n.string("Some languages need an on-device language pack.")
                    }
                } else if outcome.translatedByBlockID.isEmpty {
                    self.translationStatusMessage = L10n.string("Text is already in the target language.")
                    self.flash(L10n.string("No Translatable Text"))
                } else {
                    self.flash(L10n.string("Translated"))
                }
            } catch {
                self.translationStatusMessage = error.localizedDescription
                self.flash(L10n.string("Translation Failed"))
            }
        }
    }

    func startLanguagePackDownload() {
        guard let pair = pendingDownloadPair else { return }
        translationTaskConfig = nil
        Task { @MainActor [weak self] in
            self?.translationTaskConfig = TranslationSession.Configuration(source: pair.source, target: pair.target)
        }
    }

    func completeTranslationDownload(using session: TranslationSession) async {
        guard let pair = pendingDownloadPair else { return }
        isTranslating = true
        defer {
            isTranslating = false
            translationTaskConfig = nil
        }
        do {
            try await session.prepareTranslation()
            let lines = await ensureTextRecognized()
            let blocks = ScreenshotTextRecognizer.groupParagraphs(from: lines)
            let translated = try await translator.translate(
                blocks: blocks, using: session, source: pair.source, target: pair.target
            )
            pendingDownloadPair = nil
            translationStatusMessage = nil
            if !translated.isEmpty {
                applyTranslationResults(translated, blocks: blocks, mergeExisting: true)
                flash(L10n.string("Translated"))
            } else {
                translateImage()
            }
        } catch {
            // User cancelled download or system declined; leave pendingDownloadPair so they can retry.
            translationStatusMessage = L10n.string("Language pack download was canceled.")
        }
    }

    private func applyTranslationResults(_ translatedByID: [UUID: String], blocks: [TextParagraphBlock], mergeExisting: Bool = false) {
        guard !translatedByID.isEmpty else { return }
        var overlays: [ScreenshotTranslationOverlay] = mergeExisting ? document.translations : []
        let sourceImage = image
        for block in blocks {
            guard let translated = translatedByID[block.id], !translated.isEmpty else { continue }
            let sampled = ScreenshotPixelAnalysis.sampleBackgroundAndInk(in: sourceImage, rect: block.rect)
            let overlay = ScreenshotTranslationOverlay(
                id: block.id,
                rect: block.rect,
                sourceText: block.text,
                translatedText: translated,
                background: sampled.background,
                ink: sampled.ink,
                lineCount: block.lineCount
            )
            if let existing = overlays.firstIndex(where: { $0.id == block.id }) {
                overlays[existing] = overlay
            } else {
                overlays.append(overlay)
            }
        }
        change { doc in
            doc.translations = overlays
            doc.showsTranslations = true
        }
    }

    func setTranslationStyle(_ style: TranslationOverlayStyle) {
        change(key: "translation-style") { $0.translationStyle = style }
    }

    func setShowsTranslations(_ visible: Bool) {
        change(key: "translation-visible") { $0.showsTranslations = visible }
    }

    func clearTranslations() {
        pendingDownloadPair = nil
        translationStatusMessage = nil
        change { $0.translations = [] }
    }

    func copyTranslatedText() {
        let joined = document.translations.map(\.translatedText).joined(separator: "\n")
        guard !joined.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(joined, forType: .string)
        flash(L10n.string("Translation Copied"))
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            LibraryStore.shared.saveEdit(self.document, for: self.capture)
            if let preview = self.render(scale: min(1, 640 / max(self.imageSize.width, 1))) {
                LibraryStore.shared.savePreview(preview, for: self.capture)
            }
        }
    }

    // MARK: Output

    func render(scale: CGFloat = 1) -> Data? {
        if document.style.isPlain, document.annotations.isEmpty, document.crop == nil,
           !document.hasVisibleTranslations, scale == 1 {
            return try? Data(contentsOf: capture.url)
        }
        let content = document.crop?.size ?? imageSize
        let canvas = document.style.layout(content: content).canvas
        let renderer = ImageRenderer(content: ScreenshotComposition(model: self, document: document, crop: document.crop, interactive: false)
            .frame(width: canvas.width, height: canvas.height))
        renderer.scale = scale
        renderer.isOpaque = !document.style.background.isNone
        guard let cgImage = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    func copy() {
        guard let data = render() else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        if let tiff = NSImage(data: data)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        flash(L10n.string("Copied"))
    }

    func saveAs() {
        guard let data = render() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = capture.url.deletingPathExtension().lastPathComponent + ".png"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic); flash(L10n.string("Saved")) }
        catch { flash(error.localizedDescription) }
    }

    func share(from view: NSView?) {
        guard let data = render() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(capture.url.deletingPathExtension().lastPathComponent + ".png")
        try? data.write(to: url, options: .atomic)
        let picker = NSSharingServicePicker(items: [url])
        guard let view = view ?? NSApp.keyWindow?.contentView else { return }
        let point = view.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        picker.show(relativeTo: NSRect(origin: point, size: CGSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
    }

    func flash(_ text: String) {
        withAnimation(BrowserMotion.spring) { toast = text }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(BrowserMotion.spring) { self?.toast = nil }
        }
    }
}

private extension RGBA {
    /// Deepened tint for highlights on dark backgrounds (screen-blended so light text remains crisp).
    var darkHighlightTint: RGBA {
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let target = 0.22
        guard luminance > target, luminance > 0.001 else { return self }
        let scale = target / luminance
        return RGBA(min(1, r * scale), min(1, g * scale), min(1, b * scale), a)
    }
}

// MARK: - Composition

/// One view for the editor and the exported PNG (rendered with ImageRenderer),
/// so the result is exactly what the editor shows. Units are image pixels.
struct ScreenshotComposition: View {
    let model: ScreenshotEditorModel
    let document: ScreenshotDocument
    let crop: CGRect?
    var interactive = true

    var body: some View {
        let full = CGRect(origin: .zero, size: model.imageSize)
        let content = crop ?? full
        let style = interactive && model.tool == .crop ? CaptureStyle() : document.style
        let layout = style.layout(content: content.size)
        let shorter = min(content.width, content.height)
        let radius = style.radius(for: content.size)
        ZStack(alignment: .topLeading) {
            style.background.view
            ScreenshotContent(model: model, document: document, origin: content.origin, interactive: interactive)
                .frame(width: content.width, height: content.height)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .shadow(color: .black.opacity(style.background.isNone ? 0 : 0.32 * style.shadow),
                        radius: shorter * 0.035 * style.shadow, y: shorter * 0.012 * style.shadow)
                .offset(x: layout.content.minX, y: layout.content.minY)
        }
        .frame(width: layout.canvas.width, height: layout.canvas.height, alignment: .topLeading)
    }
}

private struct ScreenshotContent: View {
    let model: ScreenshotEditorModel
    let document: ScreenshotDocument
    /// The crop origin: annotations stay in original-image coordinates.
    let origin: CGPoint
    let interactive: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: model.image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: model.imageSize.width, height: model.imageSize.height)
            if document.hasVisibleTranslations && !(interactive && model.isPeekingOriginal) {
                TranslationOverlayLayer(
                    overlays: document.translations,
                    style: document.translationStyle,
                    imageSize: model.imageSize,
                    unit: model.unit
                )
                .frame(width: model.imageSize.width, height: model.imageSize.height, alignment: .topLeading)
            }
            AnnotationCanvas(model: model, annotations: document.annotations + (interactive ? [model.draft].compactMap { $0 } : []),
                             hiddenID: interactive ? model.editingTextID : nil)
                .frame(width: model.imageSize.width, height: model.imageSize.height)
            if interactive {
                if model.tool == .ocr {
                    ScreenshotOCRLayer(model: model)
                        .frame(width: model.imageSize.width, height: model.imageSize.height)
                } else {
                    ScreenshotInteractionLayer(model: model)
                        .frame(width: model.imageSize.width, height: model.imageSize.height)
                }
            }
        }
        .offset(x: -origin.x, y: -origin.y)
    }
}

// MARK: - Translation Overlay Layer (Exported in PNG)

struct TranslationOverlayLayer: View {
    let overlays: [ScreenshotTranslationOverlay]
    let style: TranslationOverlayStyle
    let imageSize: CGSize
    let unit: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(overlays) { overlay in
                switch style {
                case .inPlace:
                    inPlaceOverlay(overlay)
                case .callout:
                    calloutOverlay(overlay)
                }
            }
        }
        .frame(width: imageSize.width, height: imageSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func inPlaceOverlay(_ overlay: ScreenshotTranslationOverlay) -> some View {
        let padX = max(3, min(8, overlay.rect.height * 0.12))
        let padY = max(2, min(6, overlay.rect.height * 0.10))
        let patchX = max(0, overlay.rect.minX - padX)
        let patchY = max(0, overlay.rect.minY - padY)
        let patch = CGRect(
            x: patchX,
            y: patchY,
            width: min(imageSize.width - patchX, overlay.rect.width + padX * 2),
            height: min(imageSize.height - patchY, overlay.rect.height + padY * 2)
        )
        let lineH = overlay.rect.height / CGFloat(max(1, overlay.lineCount))
        let fontSize = max(10, min(lineH * 0.78, 64))
        let corner = min(8, patch.height * 0.22)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(overlay.background.color)
            Text(overlay.translatedText)
                .font(.system(size: fontSize, weight: lineH > 26 * unit ? .semibold : .regular))
                .foregroundStyle(overlay.ink.color)
                .lineLimit(max(1, overlay.lineCount + 1))
                .allowsTightening(true)
                .minimumScaleFactor(0.42)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, padX * 0.65)
                .padding(.vertical, padY * 0.4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(width: patch.width, height: patch.height, alignment: .leading)
        .clipped()
        .offset(x: patch.minX, y: patch.minY)
    }

    @ViewBuilder
    private func calloutOverlay(_ overlay: ScreenshotTranslationOverlay) -> some View {
        let lineH = overlay.rect.height / CGFloat(max(1, overlay.lineCount))
        let fontSize = max(11 * unit, min(lineH * 0.68, 22 * unit))
        let badgePadX = max(7, fontSize * 0.55)
        let badgePadY = max(4, fontSize * 0.30)
        let maxBadgeWidth = min(imageSize.width - 16, max(overlay.rect.width * 1.18, 180 * unit))
        let estimatedHeight = fontSize * 1.45 * CGFloat(max(1, min(3, overlay.lineCount))) + badgePadY * 2
        let placeAbove = overlay.rect.maxY + 4 + estimatedHeight > imageSize.height - 6
        let badgeY = placeAbove
            ? max(4, overlay.rect.minY - estimatedHeight - 4)
            : min(imageSize.height - estimatedHeight - 4, overlay.rect.maxY + 4)
        let badgeX = min(max(6, overlay.rect.minX), max(6, imageSize.width - maxBadgeWidth - 6))
        let bgLuminance = 0.2126 * overlay.background.r + 0.7152 * overlay.background.g + 0.0722 * overlay.background.b
        let darkCard = bgLuminance > 0.45

        // Subtle accent highlight framing the original text so both languages remain legible.
        RoundedRectangle(cornerRadius: max(3, unit * 3), style: .continuous)
            .fill(Color.accentColor.opacity(0.10))
            .overlay {
                RoundedRectangle(cornerRadius: max(3, unit * 3), style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: max(1, unit * 0.9))
            }
            .frame(width: overlay.rect.width + 4, height: overlay.rect.height + 2)
            .offset(x: overlay.rect.minX - 2, y: overlay.rect.minY - 1)

        // Crisp translated annotation card positioned beside the original text.
        Text(overlay.translatedText)
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(darkCard ? Color.white : Color(white: 0.1))
            .lineLimit(max(2, overlay.lineCount + 1))
            .allowsTightening(true)
            .minimumScaleFactor(0.6)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, badgePadX)
            .padding(.vertical, badgePadY)
            .background(
                RoundedRectangle(cornerRadius: max(6, fontSize * 0.48), style: .continuous)
                    .fill(darkCard ? Color(white: 0.10, opacity: 0.90) : Color.white.opacity(0.94))
            )
            .overlay {
                RoundedRectangle(cornerRadius: max(6, fontSize * 0.48), style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: max(0.8, unit * 0.7))
            }
            .shadow(color: .black.opacity(0.22), radius: max(4, unit * 4), y: max(2, unit * 1.5))
            .frame(maxWidth: maxBadgeWidth, alignment: .leading)
            .offset(x: badgeX, y: badgeY)
    }
}

// MARK: - Annotation Canvas

private struct AnnotationCanvas: View {
    let model: ScreenshotEditorModel
    let annotations: [ScreenshotAnnotation]
    let hiddenID: UUID?

    var body: some View {
        Canvas { context, size in
            // 1. Unified spotlight mask: all spotlight regions share one dimming layer so
            // multiple highlights illuminate their targets without double-darkening the rest.
            let spotlights = annotations.filter { $0.kind == .spotlight && $0.id != hiddenID && $0.rect.width > 1 && $0.rect.height > 1 }
            if !spotlights.isEmpty {
                let dimming = spotlights.map(\.effectiveDimming).max() ?? 0.55
                var maskPath = Path()
                maskPath.addRect(CGRect(origin: .zero, size: size))
                for spot in spotlights {
                    let radius = min(max(6, spot.width * 2.2), min(spot.rect.width, spot.rect.height) * 0.25)
                    maskPath.addRoundedRect(in: spot.rect, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
                }
                context.fill(maskPath, with: .color(.black.opacity(dimming)), style: FillStyle(eoFill: true))
                for spot in spotlights {
                    let radius = min(max(6, spot.width * 2.2), min(spot.rect.width, spot.rect.height) * 0.25)
                    let outline = Path(roundedRect: spot.rect, cornerRadius: radius, style: .continuous)
                    context.stroke(outline, with: .color(.black.opacity(0.30)), lineWidth: max(2, spot.width * 0.8))
                    context.stroke(outline, with: .color(.white.opacity(0.75)), lineWidth: max(1.2, spot.width * 0.45))
                }
            }

            // 2. All other annotations in drawing order.
            for annotation in annotations where annotation.id != hiddenID && annotation.kind != .spotlight {
                draw(annotation, in: &context)
            }
        }
        .allowsHitTesting(false)
    }

    /// A tapered arrow: a hairline tail that swells toward a broad, swept head.
    static func arrowPath(from start: CGPoint, to end: CGPoint, width w: CGFloat) -> Path {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return Path() }
        let u = CGPoint(x: dx / length, y: dy / length), n = CGPoint(x: -u.y, y: u.x)
        let head = min(max(w * 5.2, 24), length * 0.6)
        let headHalf = head * 0.6
        let shaftHalf = min(w * 0.95, headHalf * 0.45), tailHalf = max(0.5, w * 0.12)
        func at(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: start.x + u.x * along + n.x * across, y: start.y + u.y * along + n.y * across)
        }
        let neck = length - head * 0.78   // the shaft meets the head inside its swept wings
        let wing = length - head
        var path = Path()
        path.move(to: at(0, tailHalf))
        path.addLine(to: at(neck, shaftHalf))
        path.addLine(to: at(wing, headHalf))
        path.addLine(to: end)
        path.addLine(to: at(wing, -headHalf))
        path.addLine(to: at(neck, -shaftHalf))
        path.addLine(to: at(0, -tailHalf))
        path.closeSubpath()
        return path
    }

    private func draw(_ a: ScreenshotAnnotation, in context: inout GraphicsContext) {
        let color = a.color.color
        let stroke = StrokeStyle(lineWidth: a.width, lineCap: .round, lineJoin: .round)
        guard let start = a.points.first else { return }
        let end = a.points.last ?? start
        switch a.kind {
        case .arrow:
            let path = Self.arrowPath(from: start, to: end, width: a.width)
            var shadowed = context
            shadowed.addFilter(.shadow(color: .black.opacity(0.22), radius: a.width * 0.6, y: a.width * 0.25))
            shadowed.fill(path, with: .color(color))
            // A thin same-color stroke rounds the corners.
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: max(1, a.width * 0.35), lineJoin: .round))
        case .line:
            var path = Path(); path.move(to: start); path.addLine(to: end)
            context.stroke(path, with: .color(color), style: stroke)
        case .rectangle:
            let path = Path(roundedRect: a.rect, cornerRadius: a.width * 1.4, style: .continuous)
            if a.filled { context.fill(path, with: .color(color)) } else { context.stroke(path, with: .color(color), style: stroke) }
        case .ellipse:
            let path = Path(ellipseIn: a.rect)
            if a.filled { context.fill(path, with: .color(color)) } else { context.stroke(path, with: .color(color), style: stroke) }
        case .highlight:
            let path = Path(roundedRect: a.rect, cornerRadius: min(a.width, min(a.rect.width, a.rect.height) * 0.25), style: .continuous)
            var layer = context
            if model.isDarkGround(for: a.rect) {
                layer.blendMode = .screen
                layer.fill(path, with: .color(a.color.darkHighlightTint.color.opacity(0.85)))
            } else {
                layer.blendMode = .multiply
                layer.fill(path, with: .color(color.opacity(0.42)))
            }
        case .spotlight:
            break
        case .pen:
            var path = Path()
            path.move(to: start)
            if a.points.count > 2 {
                for index in 1..<a.points.count {
                    let mid = CGPoint(x: (a.points[index - 1].x + a.points[index].x) / 2, y: (a.points[index - 1].y + a.points[index].y) / 2)
                    path.addQuadCurve(to: mid, control: a.points[index - 1])
                }
                path.addLine(to: end)
            } else { path.addLine(to: end) }
            context.stroke(path, with: .color(color), style: stroke)
        case .text:
            let text = Text(a.text).font(.system(size: a.fontSize, weight: .semibold)).foregroundColor(color)
            var shadowed = context
            shadowed.addFilter(.shadow(color: .black.opacity(0.25), radius: a.fontSize * 0.08, y: a.fontSize * 0.04))
            shadowed.draw(text, at: start, anchor: .topLeading)
        case .step:
            let r = a.stepRadius
            let circle = Path(ellipseIn: CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2))
            var shadowed = context
            shadowed.addFilter(.shadow(color: .black.opacity(0.25), radius: r * 0.2, y: r * 0.08))
            shadowed.fill(circle, with: .color(color))
            context.stroke(circle, with: .color(.white), lineWidth: max(1.5, r * 0.12))
            let light = a.color.r * 0.299 + a.color.g * 0.587 + a.color.b * 0.114 > 0.7
            context.draw(Text("\(a.number)").font(.system(size: r * 1.1, weight: .bold, design: .rounded))
                .foregroundColor(light ? .black : .white), at: start, anchor: .center)
        case .pixelate:
            var clipped = context
            clipped.clip(to: Path(a.rect))
            clipped.draw(Image(decorative: model.pixelated, scale: 1),
                         in: CGRect(origin: .zero, size: model.imageSize))
        }
    }
}

// MARK: - Interactive On-Device OCR Overlay

private struct ScreenshotOCRLayer: View {
    @Bindable var model: ScreenshotEditorModel
    @State private var dragStart: CGPoint?
    @State private var initialSelection: Set<UUID> = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragStart == nil {
                                dragStart = value.startLocation
                                initialSelection = NSEvent.modifierFlags.contains(.shift) ? model.selectedTextLineIDs : []
                            }
                            guard let start = dragStart else { return }
                            let distance = hypot(value.location.x - start.x, value.location.y - start.y)
                            if distance > model.unit * 4 {
                                let rect = CGRect(
                                    x: min(start.x, value.location.x),
                                    y: min(start.y, value.location.y),
                                    width: abs(value.location.x - start.x),
                                    height: abs(value.location.y - start.y)
                                )
                                model.ocrMarqueeRect = rect
                                let hit = Set(model.visibleRecognizedLines.filter { $0.rect.intersects(rect) }.map(\.id))
                                model.selectedTextLineIDs = initialSelection.union(hit)
                            }
                        }
                        .onEnded { value in
                            defer {
                                dragStart = nil
                                model.ocrMarqueeRect = nil
                            }
                            guard let start = dragStart else { return }
                            let distance = hypot(value.location.x - start.x, value.location.y - start.y)
                            if distance <= model.unit * 4 {
                                if let line = model.visibleRecognizedLines.first(where: { $0.rect.insetBy(dx: -4, dy: -4).contains(value.location) }) {
                                    if model.selectedTextLineIDs.contains(line.id) {
                                        model.selectedTextLineIDs.remove(line.id)
                                    } else {
                                        model.selectedTextLineIDs.insert(line.id)
                                    }
                                } else {
                                    model.selectedTextLineIDs.removeAll()
                                }
                            }
                        }
                )

            ForEach(model.visibleRecognizedLines) { line in
                let selected = model.selectedTextLineIDs.contains(line.id)
                let hovered = model.hoveredTextLineID == line.id
                let corner = max(3, min(6, line.rect.height * 0.18))
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.accentColor.opacity(selected ? 0.30 : (hovered ? 0.16 : 0.08)))
                    .overlay {
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(
                                Color.accentColor.opacity(selected ? 0.90 : (hovered ? 0.55 : 0.25)),
                                lineWidth: max(1, model.unit * (selected ? 1.2 : 0.7))
                            )
                    }
                    .frame(width: line.rect.width + 4, height: line.rect.height + 2)
                    .offset(x: line.rect.minX - 2, y: line.rect.minY - 1)
                    .allowsHitTesting(false)
            }

            if let marquee = model.ocrMarqueeRect {
                RoundedRectangle(cornerRadius: max(3, model.unit * 3), style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: max(3, model.unit * 3), style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: max(1, model.unit))
                    }
                    .frame(width: marquee.width, height: marquee.height)
                    .offset(x: marquee.minX, y: marquee.minY)
                    .allowsHitTesting(false)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                model.hoveredTextLineID = model.visibleRecognizedLines
                    .first(where: { $0.rect.insetBy(dx: -4, dy: -4).contains(point) })?.id
            case .ended:
                model.hoveredTextLineID = nil
            }
        }
        .task {
            _ = await model.ensureTextRecognized()
        }
    }
}

/// Gestures in original-image coordinates (the scale effect above maps the pointer).
private struct ScreenshotInteractionLayer: View {
    @Bindable var model: ScreenshotEditorModel
    @State private var dragStart: CGPoint?
    @State private var moveOrigin: ScreenshotAnnotation?
    @FocusState private var textFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged(changed).onEnded(ended))
            if model.tool == .crop { cropOverlay }
            if let id = model.selectedID, model.tool == .select,
               let selected = model.document.annotations.first(where: { $0.id == id }) {
                let bounds = selected.bounds
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: max(1, model.unit * 0.8), dash: [model.unit * 4, model.unit * 3]))
                    .frame(width: bounds.width, height: bounds.height)
                    .offset(x: bounds.minX, y: bounds.minY)
                    .allowsHitTesting(false)
            }
            if let id = model.editingTextID, let annotation = model.document.annotations.first(where: { $0.id == id }) {
                TextField("", text: textBinding(id), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: annotation.fontSize, weight: .semibold))
                    .foregroundStyle(annotation.color.color)
                    .focused($textFocused)
                    .frame(minWidth: annotation.fontSize * 4, alignment: .leading)
                    .fixedSize()
                    .offset(x: annotation.points[0].x, y: annotation.points[0].y)
                    .onSubmit { finishText() }
                    // A new identity per text, so every new text takes focus.
                    .id(id)
                    .task(id: id) {
                        // After the click that placed it has been handled.
                        try? await Task.sleep(for: .milliseconds(30))
                        textFocused = true
                    }
            }
        }
        .onChange(of: model.tool) { _, _ in finishText() }
    }

    private var cropOverlay: some View {
        let full = CGRect(origin: .zero, size: model.imageSize)
        let crop = model.draftCrop ?? model.document.crop ?? full
        return ZStack(alignment: .topLeading) {
            Path { path in path.addRect(full); path.addRect(crop) }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            Rectangle()
                .strokeBorder(Color.white, lineWidth: max(1.5, model.unit))
                .frame(width: crop.width, height: crop.height)
                .offset(x: crop.minX, y: crop.minY)
        }
        .allowsHitTesting(false)
    }

    private func textBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { model.document.annotations.first { $0.id == id }?.text ?? "" },
                set: { value in model.change(key: "text-\(id)") { doc in
                    if let index = doc.annotations.firstIndex(where: { $0.id == id }) { doc.annotations[index].text = value }
                } })
    }

    private func finishText() {
        guard let id = model.editingTextID else { return }
        model.editingTextID = nil
        if model.document.annotations.first(where: { $0.id == id })?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false {
            model.change { $0.annotations.removeAll { $0.id == id } }
        }
    }

    private func hit(_ point: CGPoint) -> ScreenshotAnnotation? {
        model.document.annotations.reversed().first { $0.bounds.contains(point) }
    }

    private func changed(_ value: DragGesture.Value) {
        let point = value.location
        if dragStart == nil {
            dragStart = value.startLocation
            finishText()
            begin(at: value.startLocation)
        }
        guard let start = dragStart else { return }
        switch model.tool {
        case .select:
            if let origin = moveOrigin {
                let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
                model.change(key: "move-\(origin.id)") { doc in
                    if let index = doc.annotations.firstIndex(where: { $0.id == origin.id }) { doc.annotations[index] = origin.offset(by: delta) }
                }
            }
        case .crop:
            let full = CGRect(origin: .zero, size: model.imageSize)
            model.draftCrop = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                     width: abs(point.x - start.x), height: abs(point.y - start.y)).intersection(full)
        case .pen:
            model.draft?.points.append(point)
        case .text, .step, .ocr:
            break
        default:
            var end = point
            // Shift keeps lines straight and shapes square, as in Preview.
            if NSEvent.modifierFlags.contains(.shift) {
                let dx = point.x - start.x, dy = point.y - start.y
                if [.arrow, .line].contains(model.tool) {
                    let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4), length = hypot(dx, dy)
                    end = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
                } else {
                    let side = max(abs(dx), abs(dy))
                    end = CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
                }
            }
            model.draft?.points = [start, end]
        }
    }

    private func begin(at point: CGPoint) {
        switch model.tool {
        case .select:
            let target = hit(point)
            model.selectedID = target?.id
            moveOrigin = target
            if let target, target.kind == .text, NSApp.currentEvent?.clickCount == 2 { model.editingTextID = target.id }
        case .crop, .ocr:
            if model.tool == .crop { model.draftCrop = nil }
        case .text:
            if let existing = hit(point), existing.kind == .text {
                model.editingTextID = existing.id
                return
            }
            let annotation = ScreenshotAnnotation(kind: .text, points: [point], color: model.color, width: model.strokeWidth)
            model.change { $0.annotations.append(annotation) }
            model.editingTextID = annotation.id
        case .step:
            let annotation = ScreenshotAnnotation(kind: .step, points: [point], color: model.color, width: model.strokeWidth, number: model.nextStep)
            model.change { $0.annotations.append(annotation) }
        default:
            let kind: ScreenshotAnnotation.Kind = switch model.tool {
            case .arrow: .arrow
            case .rectangle: .rectangle
            case .ellipse: .ellipse
            case .line: .line
            case .pen: .pen
            case .highlight: .highlight
            case .spotlight: .spotlight
            default: .pixelate
            }
            let color = model.tool == .highlight && model.color == RGBA(hex: 0xFF3B30) ? RGBA(hex: 0xFFCC00) : model.color
            model.draft = ScreenshotAnnotation(
                kind: kind,
                points: [point, point],
                color: color,
                width: model.tool == .highlight ? model.strokeWidth * 3 : model.strokeWidth,
                dimming: model.tool == .spotlight ? model.spotlightDimming : nil
            )
        }
    }

    private func ended(_ value: DragGesture.Value) {
        defer { dragStart = nil; moveOrigin = nil }
        if model.editingTextID != nil { textFocused = true }
        if model.tool == .crop || model.tool == .ocr { return }
        guard var draft = model.draft else { return }
        model.draft = nil
        if draft.kind != .pen { draft.points = [draft.points[0], draft.points.last ?? draft.points[0]] }
        let size = draft.kind == .pen ? draft.bounds.size : draft.rect.size
        guard max(size.width, size.height) > model.unit * 3 else { return }
        model.change { $0.annotations.append(draft) }
    }
}

// MARK: - Editor

struct ScreenshotEditorView: View {
    let capture: LibraryCapture
    @State private var model: ScreenshotEditorModel?
    @State private var failed = false

    var body: some View {
        Group {
            if let model { ScreenshotEditor(model: model) }
            else if failed { CaptureUnavailableView(name: capture.name) }
            else { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: capture.url) {
            if let created = ScreenshotEditorModel(capture: capture) { model = created } else { failed = true }
        }
    }
}

struct CaptureUnavailableView: View {
    let name: String
    var body: some View {
        ContentUnavailableView(name, systemImage: "icloud.and.arrow.down",
                               description: Text(L10n.string("This item is not available on this Mac yet.")))
    }
}

private struct ScreenshotEditor: View {
    @Bindable var model: ScreenshotEditorModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var zoom: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let content = model.tool == .crop ? CGRect(origin: .zero, size: model.imageSize) : (model.document.crop ?? CGRect(origin: .zero, size: model.imageSize))
            let style = model.tool == .crop ? CaptureStyle() : model.document.style
            let canvas = style.layout(content: content.size).canvas
            let inspectorWidth: CGFloat = model.showsInspector ? 252 : 0
            let available = CGSize(width: geometry.size.width - inspectorWidth - 64, height: geometry.size.height - 132)
            let fit = max(0.05, min(available.width / max(canvas.width, 1), available.height / max(canvas.height, 1), 2 / max(1, model.unit)))
            let viewport = CGSize(width: geometry.size.width - inspectorWidth, height: geometry.size.height - 56)
            ZStack {
                editorBackdrop
                ZoomableCanvas(canvas: canvas, fitScale: fit, zoom: $zoom, viewport: viewport) { scale in
                    ScreenshotComposition(model: model, document: model.document, crop: model.tool == .crop ? nil : model.document.crop)
                        .frame(width: canvas.width, height: canvas.height)
                        .scaleEffect(scale)
                        .frame(width: canvas.width * scale, height: canvas.height * scale)
                        .background {
                            if style.background.isNone {
                                CheckerboardView().clipShape(RoundedRectangle(cornerRadius: 2))
                            }
                        }
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.12), radius: 24, y: 8)
                }
                .padding(.trailing, inspectorWidth)
                .padding(.top, 56)
                .animation(reduceMotion ? nil : BrowserMotion.spring, value: model.document.style)
                .animation(reduceMotion ? nil : BrowserMotion.spring, value: model.document.crop)
                .animation(reduceMotion ? nil : BrowserMotion.spring, value: model.showsInspector)
            }
            .overlay(alignment: .bottomLeading) {
                CanvasZoomControl(zoom: $zoom, scale: fit * zoom).padding(16)
            }
            .overlay(alignment: .top) { ScreenshotToolbar(model: model).padding(.top, 16) }
            .overlay(alignment: .topTrailing) {
                if model.showsInspector {
                    ScreenshotInspector(model: model)
                        .frame(width: 236)
                        .padding(.top, 66).padding(.trailing, 16).padding(.bottom, 16)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if let toast = model.toast {
                        Label(toast, systemImage: "checkmark").font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .glassEffect(.regular, in: Capsule())
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if model.tool == .ocr {
                        ocrActionBar
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.bottom, 22).padding(.trailing, inspectorWidth)
            }
            .animation(reduceMotion ? nil : BrowserMotion.spring, value: model.showsInspector)
            .animation(reduceMotion ? nil : BrowserMotion.spring, value: model.tool == .ocr)
        }
        // On-device Apple Translation pack download sheet when a language pair isn't installed yet.
        .translationTask(model.translationTaskConfig) { session in
            await model.completeTranslationDownload(using: session)
        }
        // Hold Option to peek at the original untranslated screenshot.
        .onModifierKeysChanged(mask: .option) { _, new in
            model.isPeekingOriginal = new.contains(.option)
        }
        // Keys go to the focused editor only, never to the address field or a page.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onChange(of: model.editingTextID) { _, id in if id == nil { focused = true } }
        .onKeyPress(phases: .down) { press in handle(press) }
    }

    @ViewBuilder
    private var ocrActionBar: some View {
        HStack(spacing: 8) {
            if model.isRecognizingText {
                ProgressView().controlSize(.small)
                Text(L10n.string("Recognizing text…"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                let visible = model.visibleRecognizedLines
                let total = visible.count
                let visibleIDs = Set(visible.map(\.id))
                let selected = model.selectedTextLineIDs.intersection(visibleIDs).count
                Text(selected > 0
                     ? L10n.format("%d selected", selected)
                     : (total > 0 ? L10n.format("%d lines", total) : L10n.string("No Text Found")))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)

                if total > 0 {
                    Button(selected > 0 ? L10n.string("Copy Selected") : L10n.string("Copy All")) {
                        model.copyRecognizedText(selectedOnly: selected > 0)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)

                    Button(selected == total ? L10n.string("Clear") : L10n.string("Select All")) {
                        if selected == total { model.clearRecognizedTextSelection() }
                        else { model.selectAllRecognizedText() }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    Button {
                        model.translateImage()
                    } label: {
                        Label(L10n.string("Translate"), systemImage: "translate")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(model.isTranslating)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.16), radius: 14, y: 4)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard model.editingTextID == nil else { return .ignored }
        let command = press.modifiers.contains(.command), shift = press.modifiers.contains(.shift)
        switch press.key {
        case .delete, .deleteForward:
            model.deleteSelection(); return .handled
        case .return:
            if model.tool == .crop { model.finishCrop(); return .handled }
            return .ignored
        case .escape:
            if model.tool == .crop { model.draftCrop = nil; model.tool = .select }
            else if model.tool == .ocr { model.clearRecognizedTextSelection(); model.tool = .select }
            else { model.selectedID = nil }
            return .handled
        default: break
        }
        let character = press.characters.lowercased()
        if command, let zoomed = CanvasZoom.zoom(for: character, current: zoom) {
            withAnimation(reduceMotion ? nil : BrowserMotion.spring) { zoom = zoomed }
            return .handled
        }
        if command {
            switch character {
            case "z": shift ? model.redo() : model.undo(); return .handled
            case "a" where model.tool == .ocr:
                model.selectAllRecognizedText(); return .handled
            case "c":
                if model.tool == .ocr {
                    model.copyRecognizedText(selectedOnly: !model.selectedTextLineIDs.isEmpty)
                } else {
                    model.copy()
                }
                return .handled
            case "s": model.saveAs(); return .handled
            default: return .ignored
            }
        }
        guard press.modifiers.isEmpty || press.modifiers == .shift,
              let tool = ScreenshotTool.allCases.first(where: { String($0.shortcut.character) == character }) else { return .ignored }
        withAnimation(BrowserMotion.interaction) {
            if model.tool == .crop, tool != .crop { model.finishCrop() }
            model.tool = tool
        }
        return .handled
    }

    private var editorBackdrop: some View {
        Color(nsColor: colorScheme == .dark ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.955, alpha: 1))
            .contentShape(Rectangle())
            .onTapGesture {
                model.selectedID = nil
                if model.tool == .ocr { model.clearRecognizedTextSelection() }
            }
    }
}

struct CheckerboardView: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            for row in 0..<Int(size.height / cell + 1) {
                for column in 0..<Int(size.width / cell + 1) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(.primary.opacity(0.06)))
                }
            }
        }
    }
}

private struct ScreenshotToolbar: View {
    @Bindable var model: ScreenshotEditorModel
    @Namespace private var selection
    @State private var choosingStyle = false

    private var strokePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.tool == .spotlight {
                Text(L10n.string("Backdrop Dimming"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { model.spotlightDimmingLevel },
                    set: { model.setSpotlightDimmingLevel($0) }
                )) {
                    Text(L10n.string("Light")).tag(0)
                    Text(L10n.string("Medium")).tag(1)
                    Text(L10n.string("Dark")).tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 170)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 8), count: 4), spacing: 8) {
                    ForEach(ScreenshotEditorModel.palette, id: \.self) { color in
                        Button { model.setColor(color) } label: {
                            Circle().fill(color.color)
                                .overlay { Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5) }
                                .frame(width: 20, height: 20).padding(1)
                                .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: model.color == color ? 2 : 0) }
                        }
                        .buttonStyle(.plain)
                    }
                }
                ColorPicker(L10n.string("Custom"), selection: Binding(get: { model.color.color }, set: { model.setColor(RGBA($0)) }))
                    .font(.system(size: 11))
                HStack(spacing: 4) {
                    ForEach(0..<3) { level in
                        Button { model.widthLevel = level } label: {
                            Circle().fill(Color.primary.opacity(model.widthLevel == level ? 0.85 : 0.3))
                                .frame(width: CGFloat(4 + level * 4), height: CGFloat(4 + level * 4))
                                .frame(width: 30, height: 26).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
    }

    var body: some View {
        HStack(spacing: 10) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(ScreenshotTool.allCases) { tool in
                        Button {
                            withAnimation(BrowserMotion.interaction) {
                                if model.tool == .crop, tool != .crop { model.finishCrop() }
                                model.tool = tool
                            }
                        } label: {
                            Image(systemName: tool.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 30, height: 30)
                                .background {
                                    if model.tool == tool {
                                        Circle().fill(Color.primary.opacity(0.12)).matchedGeometryEffect(id: "tool", in: selection)
                                    }
                                }
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(tool.label + "  " + String(tool.shortcut.character).uppercased())
                    }
                }
                .padding(4)
                .glassEffect(.regular, in: Capsule())

                if model.tool == .crop {
                    HStack(spacing: 4) {
                        Button(L10n.string("Reset")) { model.draftCrop = nil; model.change { $0.crop = nil } }
                        Button(L10n.string("Done")) { model.finishCrop() }
                    }
                    .buttonStyle(.glass)
                    .transition(.scale.combined(with: .opacity))
                } else if model.tool != .ocr {
                    Button { choosingStyle.toggle() } label: {
                        Group {
                            if model.tool == .spotlight {
                                Image(systemName: "circle.lefthalf.filled")
                                    .font(.system(size: 14, weight: .medium))
                            } else {
                                Circle().fill(model.color.color)
                                    .overlay { Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5) }
                                    .frame(width: 18, height: 18)
                            }
                        }
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .help(L10n.string(model.tool == .spotlight ? "Backdrop Dimming" : "Color and Width"))
                    .popover(isPresented: $choosingStyle, arrowEdge: .bottom) { strokePicker }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            HStack(spacing: 2) {
                Button {
                    if model.document.hasVisibleTranslations {
                        model.setShowsTranslations(false)
                    } else if !model.document.translations.isEmpty {
                        model.setShowsTranslations(true)
                    } else {
                        model.translateImage()
                    }
                } label: {
                    Group {
                        if model.isTranslating {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "translate")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(model.document.hasVisibleTranslations ? Color.accentColor : .primary)
                        }
                    }
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.isTranslating)
                .help(L10n.string("Translate Image"))

                iconButton("arrow.uturn.backward", L10n.string("Undo"), disabled: model.history.undoStack.isEmpty, action: model.undo)
                iconButton("arrow.uturn.forward", L10n.string("Redo"), disabled: model.history.redoStack.isEmpty, action: model.redo)
                iconButton("sidebar.right", L10n.string("Inspector"), disabled: false) { model.showsInspector.toggle() }
            }
            .padding(4)
            .glassEffect(.regular, in: Capsule())
        }
        .animation(BrowserMotion.spring, value: model.tool == .crop)
    }

    private func iconButton(_ symbol: String, _ label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 30, height: 30).contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.35 : 1).help(label)
    }
}

private struct ScreenshotInspector: View {
    @Bindable var model: ScreenshotEditorModel
    @State private var anchor = ShareAnchor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                InspectorSection(title: L10n.string("Text & Translate")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Button { model.copyRecognizedText(selectedOnly: false) } label: {
                                Label(L10n.string("Copy Text"), systemImage: "text.viewfinder")
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(model.isRecognizingText)

                            Button { model.translateImage() } label: {
                                Label(L10n.string("Translate"), systemImage: "translate")
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(model.isTranslating)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)

                        HStack {
                            Text(L10n.string("Target"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: $model.targetLanguageID) {
                                ForEach(TranslationTargetOption.presets) { option in
                                    Text(option.displayName).tag(option.identifier)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .onChange(of: model.targetLanguageID) { _, _ in
                                if !model.document.translations.isEmpty || model.pendingDownloadPair != nil {
                                    model.translateImage()
                                }
                            }
                        }

                        if model.pendingDownloadPair != nil {
                            Button {
                                model.startLanguagePackDownload()
                            } label: {
                                Label(L10n.string("Download Language Pack…"), systemImage: "arrow.down.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .controlSize(.small)
                        }

                        if let status = model.translationStatusMessage {
                            Text(status)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !model.document.translations.isEmpty {
                            Picker("", selection: Binding(
                                get: { model.document.translationStyle },
                                set: { model.setTranslationStyle($0) }
                            )) {
                                ForEach(TranslationOverlayStyle.allCases) { style in
                                    Text(style.label).tag(style)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .controlSize(.small)

                            HStack(spacing: 6) {
                                Button {
                                    model.setShowsTranslations(!model.document.showsTranslations)
                                } label: {
                                    Image(systemName: model.document.showsTranslations ? "eye" : "eye.slash")
                                }
                                .help(L10n.string(model.document.showsTranslations ? "Hide Translation" : "Show Translation"))

                                Button {
                                    model.copyTranslatedText()
                                } label: {
                                    Text(L10n.string("Copy Text"))
                                        .frame(maxWidth: .infinity)
                                }

                                Button {
                                    model.clearTranslations()
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .help(L10n.string("Clear Translation"))
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)

                            Text(L10n.string("Hold Option to compare with original."))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                InspectorSection(title: L10n.string("Background")) {
                    CaptureBackgroundPicker(background: model.styleBinding(\.background))
                }
                InspectorSection(title: L10n.string("Frame")) {
                    InspectorSlider(title: L10n.string("Padding"), value: model.styleBinding(\.padding), range: 0...0.3)
                    InspectorSlider(title: L10n.string("Corner Radius"), value: model.styleBinding(\.cornerRadius), range: 0...0.08)
                    InspectorSlider(title: L10n.string("Shadow"), value: model.styleBinding(\.shadow))
                }
                InspectorSection(title: L10n.string("Aspect Ratio")) {
                    Picker("", selection: model.styleBinding(\.aspect)) {
                        ForEach(CaptureAspect.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                }
                VStack(spacing: 8) {
                    Button { model.copy() } label: { Label(L10n.string("Copy"), systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent).controlSize(.large)
                    HStack(spacing: 8) {
                        Button { model.saveAs() } label: { Label(L10n.string("Save…"), systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }
                        Button { model.share(from: anchor.view) } label: { Label(L10n.string("Share"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                            .background(ShareAnchorView(anchor: anchor))
                    }
                    .buttonStyle(.glass).controlSize(.regular)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([model.capture.url]) } label: {
                        Text(L10n.string("Show Original in Finder")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).padding(.top, 2)
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// An NSView to anchor the system share picker beside its button.
@MainActor final class ShareAnchor { weak var view: NSView? }

struct ShareAnchorView: NSViewRepresentable {
    let anchor: ShareAnchor
    func makeNSView(context: Context) -> NSView { let view = NSView(); anchor.view = view; return view }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}
