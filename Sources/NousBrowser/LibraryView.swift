import AppKit
import AVFoundation
import SwiftUI

/// The Library tab: captures, history, downloads and updates in one place.
struct LibraryView: View {
    let controller: BrowserController
    let section: LibrarySection
    @State private var query = ""
    @Namespace private var pills
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var library: LibraryStore { .shared }

    @State private var contentWidth: CGFloat = 900

    /// Header and content share one centred column, so the title, the tabs,
    /// the search field and every "Show All" line up on the same edges.
    private static let columnWidth: CGFloat = 1100
    private static let columnPadding: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Self.columnPadding)
                .frame(maxWidth: Self.columnWidth)
                .frame(maxWidth: .infinity)
            ScrollView {
                content
                    .padding(.horizontal, Self.columnPadding)
                    .padding(.top, 10)
                    .padding(.bottom, 40)
                    .frame(maxWidth: Self.columnWidth)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width - Self.columnPadding * 2 } action: { contentWidth = $0 }
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .animation(reduceMotion ? nil : BrowserMotion.spring, value: section)
        .onAppear { library.refresh() }
    }

    private func open(_ section: LibrarySection) {
        controller.model.selectedTab?.load(NativePage.library(section).url)
    }

    // MARK: Header

    /// The title has a row of its own; below it the sections sit on the left
    /// and search and capture on the right. When that row does not fit, the
    /// sections get their own (sideways-scrolling) row above the actions.
    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            title
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    tabs
                    Spacer(minLength: 16)
                    actions(searchWidth: 200)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ScrollView(.horizontal) { tabs.padding(.vertical, 2) }
                        .scrollIndicators(.hidden)
                        .scrollClipDisabled()
                    HStack {
                        Spacer(minLength: 0)
                        actions(searchWidth: 160)
                    }
                }
            }
        }
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    private var title: some View {
        Text(L10n.string("Library"))
            .font(.custom("InstrumentSerif-Regular", size: 28))
            .lineLimit(1)
            .fixedSize()
    }

    private var tabs: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(LibrarySection.allCases) { item in
                    Button { withAnimation(reduceMotion ? nil : BrowserMotion.interaction) { open(item) } } label: {
                        HStack(spacing: 5) {
                            Text(item.title).font(.system(size: 12, weight: .medium)).fixedSize()
                            if item == .updates, BrowserUpdater.shared.showsButton {
                                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                            }
                            if item == .downloads, ChromiumDownloadCoordinator.shared.hasActiveDownloads {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .padding(.horizontal, 11).frame(height: 28)
                        .foregroundStyle(section == item ? Color.primary : Color.secondary)
                        .background {
                            if section == item {
                                Capsule().fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.09))
                                    .matchedGeometryEffect(id: "pill", in: pills)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .glassEffect(.regular, in: Capsule())
        }
        .fixedSize()
    }

    private func actions(searchWidth: CGFloat) -> some View {
        HStack(spacing: 8) {
            if section == .history || section == .all || section == .bookmarks {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField(L10n.string("Search"), text: $query).textFieldStyle(.plain).font(.system(size: 12))
                }
                .padding(.horizontal, 12).frame(width: searchWidth).frame(height: 32)
                .glassEffect(.regular, in: Capsule())
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
            captureButton("camera.viewfinder", L10n.string("Take Screenshot")) { CaptureCoordinator.shared.takeScreenshot() }
            captureButton(CaptureCoordinator.shared.isRecording ? "stop.circle.fill" : "record.circle",
                          L10n.string("Record Screen")) { CaptureCoordinator.shared.toggleRecording() }
            syncBadge
        }
        .fixedSize()
    }

    private func captureButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 32, height: 32).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(label)
    }

    @State private var showsSync = false
    private var syncBadge: some View {
        Button { showsSync.toggle() } label: {
            Image(systemName: library.isUsingICloud ? "icloud" : "icloud.slash")
                .font(.system(size: 13)).frame(width: 32, height: 32).contentShape(Circle())
                .foregroundStyle(library.isUsingICloud ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .popover(isPresented: $showsSync, arrowEdge: .bottom) { LibrarySyncPopover() }
        .help(library.isUsingICloud ? L10n.string("Syncing with iCloud") : L10n.string("Not syncing"))
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch section {
        case .all: overview
        case .screenshots: capturesGrid(.screenshot, empty: L10n.string("No Screenshots"), symbol: "camera.viewfinder")
        case .recordings: capturesGrid(.recording, empty: L10n.string("No Recordings"), symbol: "record.circle")
        case .bookmarks: LibraryBookmarksList(controller: controller, query: query, limit: nil)
        case .history: LibraryHistoryList(controller: controller, query: query, limit: nil)
        case .downloads: LibraryDownloadsList(limit: nil)
        case .updates: LibraryUpdatesView()
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 30) {
            if BrowserUpdater.shared.showsButton { LibraryUpdatesView(compact: true) }
            if !library.bookmarks.isEmpty {
                sectionHeader(L10n.string("Bookmarks"), destination: .bookmarks)
                LibraryBookmarksList(controller: controller, query: query, limit: 6)
            }
            if !library.captures.isEmpty {
                sectionHeader(L10n.string("Captures"), destination: .screenshots)
                // Two full rows at the current width, never a ragged last row.
                captureGrid(Array(library.captures.prefix(captureColumns * 2)))
            }
            if !library.downloads.isEmpty || !ChromiumDownloadCoordinator.shared.records.isEmpty {
                sectionHeader(L10n.string("Downloads"), destination: .downloads)
                LibraryDownloadsList(limit: 4)
            }
            sectionHeader(L10n.string("History"), destination: .history)
            LibraryHistoryList(controller: controller, query: query, limit: 12)
        }
    }

    private func sectionHeader(_ title: String, destination: LibrarySection) -> some View {
        HStack {
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            Button(L10n.string("Show All")) { open(destination) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func capturesGrid(_ kind: LibraryCapture.Kind, empty: String, symbol: String) -> some View {
        let items = library.captures.filter { $0.kind == kind }
        if items.isEmpty {
            ContentUnavailableView {
                Label(empty, systemImage: symbol)
            } actions: {
                Button(kind == .screenshot ? L10n.string("Take Screenshot") : L10n.string("Record Screen")) {
                    if kind == .screenshot { CaptureCoordinator.shared.takeScreenshot() } else { CaptureCoordinator.shared.toggleRecording() }
                }
                .buttonStyle(.glass)
            }
            .padding(.top, 80)
        } else {
            captureGrid(items)
        }
    }

    /// Cards stay between 200 and 280 points wide; the column count follows
    /// the available width (1 on a narrow window, up to 5 on a wide one).
    private var captureColumns: Int {
        max(1, min(5, Int((contentWidth + 18) / (200 + 18))))
    }

    private func captureGrid(_ items: [LibraryCapture]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 160), spacing: 18, alignment: .top), count: captureColumns),
                  alignment: .leading, spacing: 22) {
            ForEach(items) { capture in
                LibraryCaptureCard(capture: capture) { controller.model.openNativePage(capture.page) }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : BrowserMotion.spring, value: items.map(\.id))
    }
}

private struct LibrarySyncPopover: View {
    @Bindable private var library = LibraryStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L10n.string("Sync Library with iCloud"), isOn: $library.syncsWithICloud).toggleStyle(.switch)
            Text(library.isUsingICloud ? L10n.string("Screenshots, recordings, history and downloads sync through iCloud Drive.")
                 : LibraryStore.iCloudDriveAvailable ? L10n.string("Your Library stays on this Mac.")
                 : L10n.string("Turn on iCloud Drive in System Settings to sync your Library."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(L10n.string("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([library.root]) }
                .buttonStyle(.link).font(.system(size: 11))
        }
        .padding(16).frame(width: 280)
    }
}

// MARK: - Captures

private struct LibraryCaptureCard: View {
    let capture: LibraryCapture
    let open: () -> Void
    @State private var thumbnail: NSImage?
    @State private var duration: Double?
    @State private var hovered = false
    @State private var renaming = false
    @State private var name = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05))
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(10)
                } else if capture.isPlaceholder {
                    Image(systemName: "icloud.and.arrow.down").font(.system(size: 20)).foregroundStyle(.secondary)
                }
                if capture.kind == .recording {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Label(duration.map { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) } ?? "", systemImage: "play.fill")
                                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .glassEffect(.regular, in: Capsule())
                                .padding(10)
                        }
                    }
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(hovered ? 0.14 : 0.06), lineWidth: 1) }
            .shadow(color: .black.opacity(hovered ? 0.12 : 0), radius: 14, y: 6)
            .scaleEffect(hovered && !reduceMotion ? 1.02 : 1)
            if renaming {
                TextField("", text: $name).textFieldStyle(.plain).font(.system(size: 12, weight: .medium))
                    .onSubmit { _ = LibraryStore.shared.rename(capture, to: name); renaming = false }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(capture.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(capture.created, format: .relative(presentation: .named)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { value in withAnimation(reduceMotion ? nil : BrowserMotion.interaction) { hovered = value } }
        .onTapGesture { if !capture.isPlaceholder { open() } }
        .contextMenu {
            Group {
            Button(L10n.string("Open"), action: open)
            Button(L10n.string("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([capture.url]) }
            Button(L10n.string("Copy")) {
                NSPasteboard.general.clearContents()
                if capture.kind == .screenshot, let image = NSImage(contentsOf: capture.url) { NSPasteboard.general.writeObjects([image]) }
                else { NSPasteboard.general.writeObjects([capture.url as NSURL]) }
            }
            Button(L10n.string("Rename")) { name = capture.name; renaming = true }
            Divider()
            Button(L10n.string("Move to Trash"), role: .destructive) { LibraryStore.shared.delete(capture) }
            }
            // macOS 27 hides menu icons unless asked for.
            .labelStyle(.titleAndIcon)
        }
        .onDrag { NSItemProvider(contentsOf: capture.url) ?? NSItemProvider() }
        .task(id: "\(capture.id)-\(LibraryStore.shared.previewRevision)") { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard !capture.isPlaceholder else { return }
        if capture.kind == .screenshot {
            let preview = LibraryStore.shared.previewURL(for: capture)
            let url = FileManager.default.fileExists(atPath: preview.path) ? preview : capture.url
            thumbnail = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                                  kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary)
                else { return nil }
                return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }.value
        } else {
            let asset = AVURLAsset(url: capture.url)
            duration = try? await asset.load(.duration).seconds
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            if let image = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image {
                thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }
    }
}

// MARK: - History

private struct LibraryHistoryList: View {
    let controller: BrowserController
    let query: String
    let limit: Int?

    private var entries: [BrowserHistoryEntry] {
        let all = LibraryStore.shared.mergedHistory(local: controller.history.entries)
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace)
        let filtered = tokens.isEmpty ? all : all.filter { entry in
            let haystack = (entry.title + " " + entry.url.absoluteString).lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
        return limit.map { Array(filtered.prefix($0)) } ?? Array(filtered.prefix(600))
    }

    private var groups: [(day: Date, entries: [BrowserHistoryEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.lastVisited) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!.sorted { $0.lastVisited > $1.lastVisited }) }
    }

    var body: some View {
        if entries.isEmpty {
            Text(query.isEmpty ? L10n.string("No history yet") : L10n.string("No results"))
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 20)
        } else {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: limit == nil ? [.sectionHeaders] : []) {
                ForEach(groups, id: \.day) { group in
                    Section {
                        ForEach(group.entries) { entry in LibraryHistoryRow(controller: controller, entry: entry) }
                    } header: {
                        if limit == nil {
                            Text(dayTitle(group.day)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.vertical, 8).padding(.top, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .textBackgroundColor))
                        }
                    }
                }
                if limit == nil, query.isEmpty {
                    Button(L10n.string("Clear History…"), role: .destructive) {
                        let alert = NSAlert()
                        alert.messageText = L10n.string("Clear all history on this Mac?")
                        alert.addButton(withTitle: L10n.string("Clear History"))
                        alert.addButton(withTitle: L10n.string("Cancel"))
                        if alert.runModal() == .alertFirstButtonReturn { controller.history.removeAll() }
                    }
                    .buttonStyle(.glass).padding(.top, 20)
                }
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return L10n.string("Today") }
        if calendar.isDateInYesterday(day) { return L10n.string("Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}

private struct LibraryHistoryRow: View {
    let controller: BrowserController
    let entry: BrowserHistoryEntry
    @State private var favicon: NSImage?
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let favicon { Image(nsImage: favicon).resizable().interpolation(.high) }
                else { Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .frame(width: 16, height: 16)
            Text(entry.title).font(.system(size: 13)).lineLimit(1)
            if LibraryStore.shared.isBookmarked(entry.url) { BookmarkMark() }
            Text(entry.url.host() ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Text(entry.lastVisited, format: .dateTime.hour().minute()).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(.horizontal, 12).frame(height: 34)
        .background(Color.primary.opacity(hovered ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { controller.model.newTab(url: entry.url) }
        .contextMenu {
            Group {
            Button(L10n.string("Open in New Tab")) { controller.model.newTab(url: entry.url) }
            Button(L10n.string("Copy Link")) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.url.absoluteString, forType: .string)
            }
            BookmarkMenuButton(url: entry.url, title: entry.title)
            Divider()
            Button(L10n.string("Remove from History"), role: .destructive) { controller.history.remove(entry.id) }
            }
            // macOS 27 hides menu icons unless asked for.
            .labelStyle(.titleAndIcon)
        }
        .task(id: entry.id) {
            favicon = FaviconStore.shared.cachedImage(for: entry.url)
            if favicon == nil { favicon = await FaviconStore.shared.image(for: entry.url) }
        }
    }
}

// MARK: - Bookmarks

/// The small star that marks a bookmarked page in history and search.
struct BookmarkMark: View {
    var size: CGFloat = 9
    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Color.orange.gradient)
            .accessibilityLabel(L10n.string("Bookmarked"))
    }
}

struct BookmarkMenuButton: View {
    let url: URL
    let title: String
    var body: some View {
        let marked = LibraryStore.shared.isBookmarked(url)
        Button(L10n.string(marked ? "Remove Bookmark" : "Add Bookmark"), systemImage: marked ? "star.slash" : "star") {
            withAnimation(BrowserMotion.spring) { LibraryStore.shared.toggleBookmark(url: url, title: title) }
        }
    }
}

private struct LibraryBookmarksList: View {
    let controller: BrowserController
    let query: String
    let limit: Int?

    private var items: [LibraryBookmark] {
        let library = LibraryStore.shared
        let all = query.trimmingCharacters(in: .whitespaces).isEmpty ? library.bookmarks : library.bookmarks(matching: query, limit: 500)
        return limit.map { Array(all.prefix($0)) } ?? all
    }

    var body: some View {
        if items.isEmpty {
            if limit == nil {
                ContentUnavailableView {
                    Label(L10n.string(query.isEmpty ? "No Bookmarks" : "No results"), systemImage: "star")
                } description: {
                    if query.isEmpty { Text(L10n.string("Press ⌘D on any page.")) }
                }
                .padding(.top, 40)
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(items) { bookmark in
                    LibraryBookmarkRow(controller: controller, bookmark: bookmark)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
            .animation(BrowserMotion.spring, value: items.map(\.id))
        }
    }
}

private struct LibraryBookmarkRow: View {
    let controller: BrowserController
    let bookmark: LibraryBookmark
    @State private var favicon: NSImage?
    @State private var hovered = false
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let favicon { Image(nsImage: favicon).resizable().interpolation(.high) }
                else { Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .frame(width: 16, height: 16)
            if renaming {
                TextField("", text: $draft).textFieldStyle(.plain).font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { LibraryStore.shared.renameBookmark(bookmark.id, to: draft); renaming = false }
                    .onExitCommand { renaming = false }
                    .onChange(of: focused) { _, value in if !value { renaming = false } }
            } else {
                Text(bookmark.title).font(.system(size: 13)).lineLimit(1)
            }
            Text(bookmark.url.host() ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Button {
                withAnimation(BrowserMotion.spring) { LibraryStore.shared.removeBookmark(bookmark.id) }
            } label: {
                Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(Color.orange.gradient)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(PressSpringStyle())
            .help(L10n.string("Remove Bookmark"))
        }
        .padding(.leading, 12).padding(.trailing, 6).frame(height: 34)
        .background(Color.primary.opacity(hovered ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { if !renaming { controller.model.newTab(url: bookmark.url) } }
        .contextMenu {
            Group {
            Button(L10n.string("Open in New Tab")) { controller.model.newTab(url: bookmark.url) }
            Button(L10n.string("Copy Link")) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(bookmark.url.absoluteString, forType: .string)
            }
            Button(L10n.string("Rename…")) { draft = bookmark.title; renaming = true; focused = true }
            Divider()
            Button(L10n.string("Remove Bookmark"), role: .destructive) {
                withAnimation(BrowserMotion.spring) { LibraryStore.shared.removeBookmark(bookmark.id) }
            }
            }
            // macOS 27 hides menu icons unless asked for.
            .labelStyle(.titleAndIcon)
        }
        .draggable(bookmark.url)
        .task(id: bookmark.id) {
            favicon = FaviconStore.shared.cachedImage(for: bookmark.url)
            if favicon == nil { favicon = await FaviconStore.shared.image(for: bookmark.url) }
        }
    }
}

// MARK: - Downloads

private struct LibraryDownloadsList: View {
    let limit: Int?
    @ObservedObject private var coordinator = ChromiumDownloadCoordinator.shared

    var body: some View {
        let active = coordinator.records.filter { $0.state.isActive }
        let finished = LibraryStore.shared.downloads
        VStack(alignment: .leading, spacing: 8) {
            if active.isEmpty && finished.isEmpty {
                Text(L10n.string("No downloads yet")).font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(active) { ActiveDownloadRow(record: $0) }
            ForEach(limit.map { Array(finished.prefix(max(0, $0 - active.count))) } ?? finished) { FinishedDownloadRow(download: $0) }
            if limit == nil, !finished.isEmpty {
                Button(L10n.string("Clear List")) { LibraryStore.shared.clearDownloads() }
                    .buttonStyle(.glass).padding(.top, 12)
            }
        }
    }
}

private struct ActiveDownloadRow: View {
    @ObservedObject var record: ChromiumDownloadRecord
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle").font(.system(size: 18)).foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, isActive: true)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.finalURL?.lastPathComponent ?? record.filename).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if record.totalBytes > 0 {
                    ProgressView(value: Double(min(record.receivedBytes, record.totalBytes)), total: Double(record.totalBytes))
                        .progressViewStyle(.linear)
                    Text(ByteCountFormatter.string(fromByteCount: record.receivedBytes, countStyle: .file) + " / "
                         + ByteCountFormatter.string(fromByteCount: record.totalBytes, countStyle: .file))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    ProgressView().progressViewStyle(.linear)
                    Text(record.state == .choosingDestination ? L10n.string("Choose a save location")
                         : ByteCountFormatter.string(fromByteCount: record.receivedBytes, countStyle: .file))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Button { record.cancel() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 24) }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).help(L10n.string("Cancel"))
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct FinishedDownloadRow: View {
    let download: LibraryDownload
    @State private var hovered = false
    private var url: URL? { download.path.map(URL.init(fileURLWithPath:)) }
    private var exists: Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let url, exists { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable() }
                else { Image(systemName: download.state == .completed ? "doc" : "exclamationmark.triangle").foregroundStyle(.secondary) }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(download.filename).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(download.state == .failed ? Color.red : Color.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let url, exists, hovered {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).frame(width: 26, height: 26)
                }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).help(L10n.string("Show in Finder"))
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12).frame(height: 50)
        .background(Color.primary.opacity(hovered ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onHover { value in withAnimation(BrowserMotion.interaction) { hovered = value } }
        .onTapGesture(count: 2) { if let url, exists { NSWorkspace.shared.open(url) } }
        .contextMenu {
            Group {
            if let url, exists {
                Button(L10n.string("Open")) { NSWorkspace.shared.open(url) }
                Button(L10n.string("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button(L10n.string("Remove from List")) { LibraryStore.shared.removeDownload(download.id) }
            }
            // macOS 27 hides menu icons unless asked for.
            .labelStyle(.titleAndIcon)
        }
    }

    private var detail: String {
        var parts: [String] = []
        switch download.state {
        case .completed: parts.append(ByteCountFormatter.string(fromByteCount: download.size, countStyle: .file))
        case .canceled: parts.append(L10n.string("Canceled"))
        case .failed: parts.append(download.message ?? L10n.string("Failed"))
        }
        if download.state == .completed, !exists { parts.append(L10n.string("Moved or deleted")) }
        if download.device != LibraryStore.shared.deviceID { parts.append(download.device.components(separatedBy: " ").dropLast().joined(separator: " ")) }
        parts.append(download.date.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Updates

struct LibraryUpdatesView: View {
    var compact = false
    @Bindable private var updater = BrowserUpdater.shared
    private var currentVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    if updater.showsButton {
                        Text(L10n.string("Nous Browser") + " " + updater.version).font(.system(size: 16, weight: .semibold))
                        Text(L10n.string("A new version is ready to download.")).font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Text(L10n.string("Nous Browser is up to date")).font(.system(size: 16, weight: .semibold))
                        Text(L10n.string("Version") + " " + currentVersion).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                actions
            }
            if updater.phase == .downloading || updater.phase == .installing {
                VStack(alignment: .leading, spacing: 6) {
                    if let progress = updater.progress { ProgressView(value: progress) } else { ProgressView().progressViewStyle(.linear) }
                    Text(updater.status).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
            if updater.showsButton, !compact, let notes = updater.releaseNotes {
                Text(notes).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !updater.isEnabled, !compact {
                Text(L10n.string("Updates are managed outside the app for this copy of Nous Browser."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.top, compact ? 0 : 8)
        .animation(BrowserMotion.spring, value: updater.phase)
    }

    @ViewBuilder private var actions: some View {
        switch updater.phase {
        case .available:
            Button(L10n.string("Download and Install")) { updater.installUpdate(inline: true) }
                .buttonStyle(.glassProminent)
        case .checking:
            ProgressView().controlSize(.small)
        case .downloading:
            if updater.canCancel { Button(L10n.string("Cancel")) { updater.cancel() }.buttonStyle(.glass) }
        case .installing:
            EmptyView()
        case .idle:
            Button(L10n.string("Check for Updates")) { updater.checkForUpdates(inline: true) }
                .buttonStyle(.glass).disabled(!updater.isEnabled)
        }
    }
}
