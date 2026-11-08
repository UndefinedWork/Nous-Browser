import AppKit
import AVFoundation
import AVKit
import SwiftUI

// A recording editor in a tab, after Screen Studio/OpenScreen: framed video,
// automatic zoom that follows the pointer, a smoothed cursor with click
// ripples, trimming, and export through the same renderer as the preview.

@MainActor
@Observable
final class RecordingEditorModel {
    let capture: LibraryCapture
    let asset: AVURLAsset
    let player = AVPlayer()
    private(set) var document: RecordingDocument
    let history = EditorHistory<RecordingDocument>()
    private(set) var duration: Double = 0
    private(set) var sourceSize = CGSize(width: 1920, height: 1080)
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var thumbnails: [CGImage] = []
    private(set) var isReady = false
    private(set) var exportProgress: Double?
    var selectedZoomID: UUID?
    var showsInspector = (NSApp.keyWindow?.frame.width ?? 1200) >= 1000
    var toast: String?
    /// AVPlayer drops a composition whose instructions run past the asset, so use its exact duration.
    @ObservationIgnored private var assetDuration = CMTime.zero
    @ObservationIgnored private var videoTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var compositionTask: Task<Void, Never>?

    var trimEnd: Double { document.trimEnd ?? duration }

    init(capture: LibraryCapture) {
        self.capture = capture
        asset = AVURLAsset(url: capture.url)
        document = LibraryStore.shared.loadEdit(RecordingDocument.self, for: capture) ?? RecordingDocument()
        RecordingCompositor.prepareCursor()
    }

    func load() async {
        do {
            let exact = try await asset.load(.duration)
            assetDuration = exact
            let duration = exact.seconds
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let oriented = size.applying(transform)
            self.duration = duration
            sourceSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            videoTrackID = track.trackID
            if !document.zoomsGenerated {
                document.zooms = RecordingDocument.autoZooms(clicks: document.cursor.clicks, duration: duration, scale: document.zoomScale)
                document.zoomsGenerated = true
                if !document.hasCursorTrack { document.showsCursor = false }
                save()
            }
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = previewComposition()
            player.replaceCurrentItem(with: item)
            player.actionAtItemEnd = .pause
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.tick(time.seconds) }
            }
            // A seek before the item is ready shows no frame.
            for _ in 0..<100 where item.status == .unknown { try? await Task.sleep(for: .milliseconds(30)) }
            if item.status == .failed { flash(item.error?.localizedDescription ?? L10n.string("This recording can't be played.")) }
            isReady = true
            seek(to: document.trimStart)
            await makeThumbnails()
        } catch {
            flash(error.localizedDescription)
        }
    }

    func teardown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        compositionTask?.cancel()
        saveTask?.cancel()
        save()
    }

    private func tick(_ time: Double) {
        currentTime = time
        if isPlaying, time >= trimEnd - 0.02 {
            player.pause()
            isPlaying = false
            seek(to: trimEnd)
        }
    }

    private func makeThumbnails() async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
        let count = 14
        var images: [CGImage] = []
        for index in 0..<count {
            let time = CMTime(seconds: duration * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image { images.append(image) }
        }
        thumbnails = images
    }

    // MARK: Editing

    func change(key: String? = nil, _ mutate: (inout RecordingDocument) -> Void) {
        var next = document
        mutate(&next)
        guard next != document else { return }
        history.record(document, key: key)
        document = next
        documentChanged()
    }

    func undo() { if let previous = history.undo(document) { document = previous; documentChanged() } }
    func redo() { if let next = history.redo(document) { document = next; documentChanged() } }

    func binding<T>(_ path: WritableKeyPath<RecordingDocument, T>) -> Binding<T> {
        Binding(get: { self.document[keyPath: path] }, set: { value in self.change(key: "\(path)") { $0[keyPath: path] = value } })
    }

    func styleBinding<T>(_ path: WritableKeyPath<CaptureStyle, T>) -> Binding<T> {
        Binding(get: { self.document.style[keyPath: path] }, set: { value in self.change(key: "style\(path)") { $0.style[keyPath: path] = value } })
    }

    private func documentChanged() {
        // Rebuilding the composition per slider tick would stall the player.
        compositionTask?.cancel()
        compositionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let self else { return }
            self.player.currentItem?.videoComposition = self.previewComposition()
            if !self.isPlaying { self.seek(to: self.currentTime) }
        }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() { LibraryStore.shared.saveEdit(document, for: capture) }

    private func previewComposition() -> AVVideoComposition {
        let settings = RecordingRenderSettings(document: document, sourceSize: sourceSize,
            renderSize: RecordingComposer.renderSize(source: sourceSize, style: document.style, maxWidth: 1600), timeOffset: 0)
        return RecordingComposer.videoComposition(track: videoTrackID, duration: assetDuration, settings: settings)
    }

    func regenerateZooms() {
        change { doc in
            doc.zooms = RecordingDocument.autoZooms(clicks: doc.cursor.clicks, duration: duration, scale: doc.zoomScale)
        }
    }

    func addZoom(at time: Double) {
        let start = min(max(0, time - 0.2), max(0, duration - 0.5))
        let segment = ZoomSegment(start: start, end: min(duration, start + 2), scale: document.zoomScale)
        change { $0.zooms.append(segment); $0.zooms.sort { $0.start < $1.start } }
        selectedZoomID = segment.id
    }

    func deleteSelectedZoom() {
        guard let id = selectedZoomID else { return }
        change { $0.zooms.removeAll { $0.id == id } }
        selectedZoomID = nil
    }

    func updateZoom(_ id: UUID, key: String, _ mutate: (inout ZoomSegment) -> Void) {
        change(key: key + id.uuidString) { doc in
            guard let index = doc.zooms.firstIndex(where: { $0.id == id }) else { return }
            mutate(&doc.zooms[index])
            doc.zooms[index].start = max(0, doc.zooms[index].start)
            doc.zooms[index].end = min(duration, max(doc.zooms[index].start + 0.3, doc.zooms[index].end))
        }
    }

    // MARK: Playback

    func togglePlay() {
        if isPlaying { player.pause(); isPlaying = false; return }
        if currentTime >= trimEnd - 0.05 || currentTime < document.trimStart { seek(to: document.trimStart) }
        player.play()
        isPlaying = true
    }

    func seek(to time: Double) {
        let clamped = min(max(0, time), duration)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Export

    func export(saveAs: Bool) {
        guard exportProgress == nil, isReady else { return }
        var destination: URL
        if saveAs {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = capture.name + ".mp4"
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
            try? FileManager.default.removeItem(at: url)
        } else {
            destination = LibraryStore.shared.uniqueURL(in: LibraryStore.shared.recordingsFolder,
                                                        name: capture.name + " " + L10n.string("Edited") + ".mp4")
        }
        let document = document, sourceSize = sourceSize, asset = asset, trackID = videoTrackID
        let range = CMTimeRange(start: CMTime(seconds: document.trimStart, preferredTimescale: 600),
                                end: CMTimeMinimum(CMTime(seconds: trimEnd, preferredTimescale: 600), assetDuration))
        exportProgress = 0
        Task {
            do {
                let composition = AVMutableComposition()
                guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first(where: { $0.trackID == trackID }),
                      let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try video.insertTimeRange(range, of: sourceVideo, at: .zero)
                for audio in try await asset.loadTracks(withMediaType: .audio) {
                    let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    try track?.insertTimeRange(range, of: audio, at: .zero)
                }
                let settings = RecordingRenderSettings(document: document, sourceSize: sourceSize,
                    renderSize: RecordingComposer.renderSize(source: sourceSize, style: document.style, maxWidth: 3840),
                    timeOffset: document.trimStart)
                let videoComposition = RecordingComposer.videoComposition(track: video.trackID, duration: composition.duration, settings: settings)
                guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                    throw CocoaError(.featureUnsupported)
                }
                session.videoComposition = videoComposition
                let progress = Task { [weak self] in
                    for await state in session.states(updateInterval: 0.1) {
                        if case .exporting(let value) = state { self?.exportProgress = value.fractionCompleted }
                    }
                }
                try await session.export(to: destination, as: .mp4)
                progress.cancel()
                exportProgress = nil
                LibraryStore.shared.refresh()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([destination as NSURL])
                flash(L10n.string("Exported · Copied"))
                if saveAs { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            } catch {
                exportProgress = nil
                flash(L10n.string("Export failed:") + " " + error.localizedDescription)
            }
        }
    }

    func flash(_ text: String) {
        withAnimation(BrowserMotion.spring) { toast = text }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(BrowserMotion.spring) { self?.toast = nil }
        }
    }
}

// MARK: - Views

struct RecordingEditorView: View {
    let capture: LibraryCapture
    @State private var model: RecordingEditorModel?

    var body: some View {
        Group {
            if let model { RecordingEditor(model: model) }
            else { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: capture.url) {
            let created = RecordingEditorModel(capture: capture)
            model = created
            await created.load()
        }
        .onDisappear { model?.teardown() }
    }
}

private struct RecordingEditor: View {
    @Bindable var model: RecordingEditorModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            let inspectorWidth: CGFloat = model.showsInspector ? 252 : 0
            let canvas = model.document.style.layout(content: model.sourceSize).canvas
            let available = CGSize(width: geometry.size.width - inspectorWidth - 64, height: geometry.size.height - 210)
            let scale = max(0.05, min(available.width / max(canvas.width, 1), available.height / max(canvas.height, 1)))
            ZStack(alignment: .top) {
                Color(nsColor: colorScheme == .dark ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.955, alpha: 1))
                VStack(spacing: 18) {
                    PlayerSurface(player: model.player)
                        .frame(width: canvas.width * scale, height: canvas.height * scale)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.12), radius: 24, y: 8)
                        .overlay { if !model.isReady { ProgressView().controlSize(.small) } }
                        .onTapGesture { model.togglePlay() }
                        .animation(reduceMotion ? nil : BrowserMotion.spring, value: model.document.style)
                        .frame(maxHeight: .infinity)
                    RecordingTimeline(model: model)
                        .frame(height: 118)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                }
                .padding(.top, 24)
                .padding(.trailing, inspectorWidth)
            }
            .overlay(alignment: .topTrailing) {
                if model.showsInspector {
                    RecordingInspector(model: model)
                        .frame(width: 236)
                        .padding(16)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .top) {
                if let toast = model.toast {
                    Label(toast, systemImage: "checkmark").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.top, 16).padding(.trailing, inspectorWidth)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : BrowserMotion.spring, value: model.showsInspector)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in
            let command = press.modifiers.contains(.command)
            switch press.key {
            case .space: model.togglePlay(); return .handled
            case .delete, .deleteForward: model.deleteSelectedZoom(); return .handled
            case .leftArrow: model.seek(to: model.currentTime - (press.modifiers.contains(.shift) ? 1 : 1.0 / 30)); return .handled
            case .rightArrow: model.seek(to: model.currentTime + (press.modifiers.contains(.shift) ? 1 : 1.0 / 30)); return .handled
            default: break
            }
            if command, press.characters.lowercased() == "z" {
                press.modifiers.contains(.shift) ? model.redo() : model.undo()
                return .handled
            }
            if press.modifiers.isEmpty, press.characters == "z" { model.addZoom(at: model.currentTime); return .handled }
            return .ignored
        }
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.allowsMagnification = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

private struct RecordingTimeline: View {
    @Bindable var model: RecordingEditorModel
    @State private var trimDragOrigin: Double?
    @State private var zoomDragOrigin: ZoomSegment?

    private func label(_ seconds: Double) -> String {
        let total = max(0, seconds)
        return String(format: "%d:%02d.%d", Int(total) / 60, Int(total) % 60, Int((total * 10).truncatingRemainder(dividingBy: 10)))
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                Text("\(label(model.currentTime)) / \(label(model.duration))")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button { model.addZoom(at: model.currentTime) } label: {
                    Label(L10n.string("Add Zoom"), systemImage: "plus.magnifyingglass").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.glass).controlSize(.small)
                .help(L10n.string("Add Zoom") + "  Z")
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                let x = { (t: Double) -> CGFloat in model.duration > 0 ? CGFloat(t / model.duration) * width : 0 }
                VStack(spacing: 6) {
                    ZStack(alignment: .leading) {
                        filmstrip(width: width)
                        // Outside the trim is dimmed.
                        Rectangle().fill(.black.opacity(0.45)).frame(width: x(model.document.trimStart))
                        Rectangle().fill(.black.opacity(0.45)).frame(width: max(0, width - x(model.trimEnd))).offset(x: x(model.trimEnd))
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.yellow, lineWidth: 2.5)
                            .frame(width: max(8, x(model.trimEnd) - x(model.document.trimStart)))
                            .offset(x: x(model.document.trimStart))
                            .allowsHitTesting(false)
                        trimHandle(isStart: true, width: width).offset(x: x(model.document.trimStart) - 5)
                        trimHandle(isStart: false, width: width).offset(x: x(model.trimEnd) - 5)
                    }
                    .frame(height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    zoomTrack(width: width, x: x)
                }
                .overlay(alignment: .topLeading) {
                    Capsule().fill(Color.primary).frame(width: 2, height: 74).offset(x: x(model.currentTime) - 1, y: -2)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard model.duration > 0 else { return }
                    model.seek(to: Double(value.location.x / width) * model.duration)
                })
            }
        }
    }

    private func filmstrip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: width / CGFloat(max(1, model.thumbnails.count)), height: 46).clipped()
            }
        }
        .frame(width: width, height: 46, alignment: .leading)
        .background(Color.primary.opacity(0.08))
    }

    private func trimHandle(isStart: Bool, width: CGFloat) -> some View {
        Capsule().fill(Color.yellow).frame(width: 10, height: 46)
            .overlay { Capsule().fill(.black.opacity(0.5)).frame(width: 2, height: 14) }
            .contentShape(Rectangle().inset(by: -6))
            .highPriorityGesture(DragGesture(minimumDistance: 1).onChanged { value in
                guard model.duration > 0 else { return }
                let origin = trimDragOrigin ?? (isStart ? model.document.trimStart : model.trimEnd)
                trimDragOrigin = origin
                let time = origin + Double(value.translation.width / width) * model.duration
                model.change(key: isStart ? "trimStart" : "trimEnd") { doc in
                    if isStart { doc.trimStart = min(max(0, time), (doc.trimEnd ?? model.duration) - 0.5) }
                    else { doc.trimEnd = max(min(model.duration, time), doc.trimStart + 0.5) }
                }
                model.seek(to: isStart ? model.document.trimStart : model.trimEnd)
            }.onEnded { _ in trimDragOrigin = nil })
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    private func zoomTrack(width: CGFloat, x: @escaping (Double) -> CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06))
                .onTapGesture(count: 2) { location in
                    guard model.duration > 0 else { return }
                    model.addZoom(at: Double(location.x / width) * model.duration)
                }
            ForEach(model.document.zooms) { segment in
                let selected = model.selectedZoomID == segment.id
                HStack(spacing: 4) {
                    Image(systemName: "plus.magnifyingglass").font(.system(size: 9, weight: .semibold))
                    Text(String(format: "%.1f×", segment.scale)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                }
                .foregroundStyle(selected ? Color.white : Color.accentColor)
                .frame(width: max(24, x(segment.end) - x(segment.start)), height: 22)
                .background(selected ? Color.accentColor : Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .offset(x: x(segment.start))
                .highPriorityGesture(DragGesture(minimumDistance: 2).onChanged { value in
                    let origin = zoomDragOrigin ?? segment
                    zoomDragOrigin = origin
                    let delta = Double(value.translation.width / width) * model.duration
                    model.selectedZoomID = segment.id
                    model.updateZoom(segment.id, key: "move") { zoom in
                        let length = origin.end - origin.start
                        zoom.start = min(max(0, origin.start + delta), model.duration - length)
                        zoom.end = zoom.start + length
                    }
                }.onEnded { _ in zoomDragOrigin = nil })
                .onTapGesture { withAnimation(BrowserMotion.interaction) { model.selectedZoomID = selected ? nil : segment.id } }
            }
        }
        .frame(height: 22)
        .animation(BrowserMotion.interaction, value: model.selectedZoomID)
    }
}

private struct RecordingInspector: View {
    @Bindable var model: RecordingEditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                InspectorSection(title: L10n.string("Background")) {
                    CaptureBackgroundPicker(background: model.styleBinding(\.background))
                }
                InspectorSection(title: L10n.string("Frame")) {
                    InspectorSlider(title: L10n.string("Padding"), value: model.styleBinding(\.padding), range: 0...0.25)
                    InspectorSlider(title: L10n.string("Corner Radius"), value: model.styleBinding(\.cornerRadius), range: 0...0.06)
                    InspectorSlider(title: L10n.string("Shadow"), value: model.styleBinding(\.shadow))
                    Picker("", selection: model.styleBinding(\.aspect)) {
                        ForEach(CaptureAspect.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                }
                InspectorSection(title: L10n.string("Zoom")) {
                    if let id = model.selectedZoomID, let segment = model.document.zooms.first(where: { $0.id == id }) {
                        InspectorSlider(title: L10n.string("Selected Zoom") + String(format: "  %.1f×", segment.scale),
                                        value: Binding(get: { segment.scale }, set: { value in
                                            model.updateZoom(id, key: "scale") { $0.scale = value }
                                        }), range: 1.2...3)
                        Button(role: .destructive) { model.deleteSelectedZoom() } label: { Label(L10n.string("Remove Zoom"), systemImage: "trash") }
                            .buttonStyle(.glass).controlSize(.small)
                    } else {
                        InspectorSlider(title: L10n.string("Default Zoom") + String(format: "  %.1f×", model.document.zoomScale),
                                        value: model.binding(\.zoomScale), range: 1.2...3)
                        Button { model.regenerateZooms() } label: { Label(L10n.string("Zoom on Clicks"), systemImage: "cursorarrow.click.2") }
                            .buttonStyle(.glass).controlSize(.small)
                            .disabled(model.document.cursor.clicks.isEmpty)
                    }
                }
                if model.document.hasCursorTrack {
                    InspectorSection(title: L10n.string("Cursor")) {
                        Toggle(L10n.string("Show Cursor"), isOn: model.binding(\.showsCursor)).controlSize(.small)
                        Toggle(L10n.string("Click Effect"), isOn: model.binding(\.clickEffect)).controlSize(.small)
                        InspectorSlider(title: L10n.string("Size"), value: model.binding(\.cursorScale), range: 0.8...3)
                        InspectorSlider(title: L10n.string("Smoothing"), value: model.binding(\.cursorSmoothing))
                    }
                }
                VStack(spacing: 8) {
                    if let progress = model.exportProgress {
                        ProgressView(value: progress).progressViewStyle(.linear)
                        Text(L10n.string("Exporting…")).font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Button { model.export(saveAs: false) } label: {
                            Label(L10n.string("Export"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent).controlSize(.large)
                        Button { model.export(saveAs: true) } label: {
                            Label(L10n.string("Export As…"), systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .animation(BrowserMotion.spring, value: model.exportProgress == nil)
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
