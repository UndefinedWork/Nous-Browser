import AppKit
import Foundation
import Observation

nonisolated enum SidebarSizing {
    static let defaultWidth: Double = 243
    static let minimumWidth: Double = 180
    static let maximumWidth: Double = 420
    static let minimumPageWidth: Double = 320

    static func clampedWidth(_ width: Double) -> Double {
        guard width.isFinite else { return defaultWidth }
        return min(maximumWidth, max(minimumWidth, width))
    }

    /// A narrow window temporarily limits the rendered sidebar without changing
    /// the user's preferred width, which can be restored when the window grows.
    static func effectiveWidth(preferred: Double, windowWidth: Double) -> Double {
        let availableWidth = windowWidth.isFinite
            ? max(minimumWidth, windowWidth - minimumPageWidth)
            : maximumWidth
        return min(clampedWidth(preferred), availableWidth)
    }
}

/// Tabs are restored separately from Chromium's persistent cookie and website-data store.
/// Credentials are never serialized into this file.
struct BrowserSession: Codable, Equatable {
    struct Tab: Codable, Equatable {
        var id: UUID
        var title: String
        var url: URL?
        var isPinned: Bool

        init(id: UUID, title: String, url: URL?, isPinned: Bool = false) {
            self.id = id
            self.title = title
            self.url = url
            self.isPinned = isPinned
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, url, isPinned
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            url = try container.decodeIfPresent(URL.self, forKey: .url)
            // Earlier sessions have no pin preference; preserve all their tabs.
            isPinned = (try? container.decode(Bool.self, forKey: .isPinned)) ?? false
        }
    }

    /// The ordinary (unpinned) tabs and folders of one space in this window.
    struct Space: Codable, Equatable {
        var id: UUID
        var regular: [SidebarNodeRecord]
        var selectedTabID: UUID?
    }

    /// Every ordinary tab, flattened. Earlier versions read only this list.
    var tabs: [Tab]
    var selectedTabID: UUID?
    var isSidebarVisible: Bool
    var sidebarWidth: Double
    /// Kept independently of visibility so fully hiding the sidebar can restore
    /// the user's previous expanded or icon-only presentation.
    var isSidebarCompact: Bool
    var activeSpaceID: UUID?
    /// nil for sessions written before spaces existed.
    var spaces: [Space]?

    init(tabs: [Tab], selectedTabID: UUID?, isSidebarVisible: Bool, sidebarWidth: Double = SidebarSizing.defaultWidth,
         isSidebarCompact: Bool = false, activeSpaceID: UUID? = nil, spaces: [Space]? = nil) {
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.isSidebarVisible = isSidebarVisible
        self.sidebarWidth = sidebarWidth
        self.isSidebarCompact = isSidebarCompact
        self.activeSpaceID = activeSpaceID
        self.spaces = spaces
    }

    private enum CodingKeys: String, CodingKey {
        case tabs, selectedTabID, isSidebarVisible, sidebarWidth, isSidebarCompact, activeSpaceID, spaces
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try container.decode([Tab].self, forKey: .tabs)
        selectedTabID = try container.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        isSidebarVisible = try container.decode(Bool.self, forKey: .isSidebarVisible)
        // Layout preferences are optional for sessions written by earlier builds.
        // An invalid layout value must not discard the user's tabs either.
        sidebarWidth = (try? container.decode(Double.self, forKey: .sidebarWidth)) ?? SidebarSizing.defaultWidth
        isSidebarCompact = (try? container.decode(Bool.self, forKey: .isSidebarCompact)) ?? false
        activeSpaceID = try? container.decodeIfPresent(UUID.self, forKey: .activeSpaceID)
        spaces = try? container.decodeIfPresent([Space].self, forKey: .spaces)
    }
}

/// What the sidebar drags: a tab or a whole folder.
nonisolated enum SidebarItemRef: Equatable, Hashable, Sendable {
    case tab(UUID)
    case group(UUID)

    var id: UUID {
        switch self {
        case .tab(let id), .group(let id): id
        }
    }
}

/// A drop position: an index in a section, or inside a folder.
nonisolated struct SidebarDropTarget: Equatable, Sendable {
    var section: SidebarSection
    var groupID: UUID?
    var index: Int
}

extension SpaceLayout {
    /// Removing the item first makes `target.index` independent of where it came from.
    func moving(_ item: SidebarItemRef, to target: SidebarDropTarget) -> SpaceLayout {
        var layout = self
        switch item {
        case .tab(let id):
            guard layout.removeTab(id) else { return self }
            layout.insertTab(id, section: target.section, groupID: target.groupID, index: target.index)
        case .group(let id):
            guard let (group, _, _) = layout.removeGroup(id) else { return self }
            layout.update(target.section) { nodes in
                nodes.insert(.group(group), at: min(max(0, target.index), nodes.count))
            }
        }
        return layout
    }
}

@MainActor
@Observable
final class BrowserModel {
    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedTabID: UUID? {
        didSet {
            guard oldValue != selectedTabID else { return }
            // Only the old/new selection changes. Do not resubmit metadata for
            // every background renderer on each keyboard tab switch.
            if let selectedTab { synchronizeChromiumLifecycleState(for: selectedTab) }
            if let previous = tabs.first(where: { $0.id == oldValue }) {
                synchronizeChromiumLifecycleState(for: previous)
            }
            if let selectedTabID, let space = tab(selectedTabID)?.spaceID { selectionBySpace[space] = selectedTabID }
        }
    }
    /// Each space's tabs and folders, in display order.
    private(set) var layouts: [UUID: SpaceLayout] = [:] {
        didSet { orderTabsLikeSidebar() }
    }
    private(set) var activeSpaceID: UUID
    private(set) var sidebarWidth = SidebarSizing.defaultWidth
    var isSidebarVisible = true {
        didSet { scheduleSave() }
    }
    var isSidebarCompact = false {
        didSet { scheduleSave() }
    }
    var isPageFullscreen: Bool {
        selectedTab?.isPageFullscreen == true
    }
    // HTML fullscreen temporarily hides browser chrome without changing the
    // saved expanded/compact/hidden sidebar preference.
    var isSidebarPresented: Bool { isSidebarVisible && !isPageFullscreen }

    let spaceStore: BrowserSpaceStore
    @ObservationIgnored private var selectionBySpace: [UUID: UUID] = [:]
    @ObservationIgnored private let sessionURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var closedTabs: [BrowserSession.Tab] = []
    @ObservationIgnored private var isRestoring = true
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var storeObserver: NSObjectProtocol?
    @ObservationIgnored var onLastTabClosed: (() -> Void)?
    @ObservationIgnored var onVisit: ((URL, String) -> Void)?
    @ObservationIgnored var onPageTitleChanged: ((URL, String) -> Void)?
    @ObservationIgnored var onOpenLinkInNewWindow: ((URL) -> Void)?
    @ObservationIgnored weak var chromiumPresentationWindow: NSWindow? {
        didSet {
            for tab in tabs { tab.webView.dialogPresentationWindow = chromiumPresentationWindow }
        }
    }
    @ObservationIgnored var onCreateChromiumPopupWindow: (() -> BrowserTab?)?
    @ObservationIgnored var onOpenChromiumImageWindow: ((URL) -> Void)?
    @ObservationIgnored var onDownloadNotice: ((String, Bool) -> Void)?
    @ObservationIgnored var onLastChromiumTabClose: ((@escaping (Bool) -> Void) -> Void)?
    @ObservationIgnored private var pendingTabCloses: Set<UUID> = []
    @ObservationIgnored private var windowCloseTransactionID: UUID?
    @ObservationIgnored private var windowCloseTransaction: ChromiumCloseTransaction?
    @ObservationIgnored private var closedWindowTabIDs: Set<UUID> = []
    @ObservationIgnored private var windowCloseApproved = false
    @ObservationIgnored var searchEngineProvider: () -> BrowserSearchEngine = { .google }

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabID } }
    var addressDisplay: String { selectedTab?.url?.absoluteString ?? "" }
    var canRestoreClosedTab: Bool { !closedTabs.isEmpty }
    var spaces: [BrowserSpaceRecord] { spaceStore.spaces }
    var activeSpace: BrowserSpaceRecord? { spaceStore.space(activeSpaceID) }
    var activeLayout: SpaceLayout { layouts[activeSpaceID] ?? SpaceLayout() }
    func layout(for spaceID: UUID) -> SpaceLayout { layouts[spaceID] ?? SpaceLayout() }
    func tab(_ id: UUID) -> BrowserTab? { tabs.first { $0.id == id } }

    /// The active space's tabs in sidebar order, including folder contents.
    var visibleTabs: [BrowserTab] { activeLayout.allTabIDs.compactMap(tab) }

    init(sessionURL: URL? = nil, restoreSession: Bool = true, loadSelectedTab: Bool = true, startWithBlankTab: Bool = false,
         initialTab: BrowserTab? = nil, spaceStore: BrowserSpaceStore? = nil) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nous Browser", isDirectory: true)
        self.sessionURL = sessionURL ?? directory.appendingPathComponent("session.json")
        // A standalone model keeps its spaces and pins beside its session file.
        let store = spaceStore ?? BrowserSpaceStore(fileURL: sessionURL.map(BrowserSpaceStore.fileURL(besideSession:)))
        self.spaceStore = store
        activeSpaceID = store.defaultSpaceID
        for space in store.spaces { layouts[space.id] = SpaceLayout() }

        let session = restoreSession && initialTab == nil
            ? (try? Data(contentsOf: self.sessionURL)).flatMap { try? JSONDecoder().decode(BrowserSession.self, from: $0) }
            : nil
        if let session {
            isSidebarVisible = session.isSidebarVisible
            isSidebarCompact = session.isSidebarCompact
            sidebarWidth = SidebarSizing.clampedWidth(session.sidebarWidth)
            if let activeID = session.activeSpaceID, store.space(activeID) != nil { activeSpaceID = activeID }
        }
        // Migrate pins from a session written before pins were shared.
        if let session, session.spaces == nil {
            let legacyPins = session.tabs.filter(\.isPinned)
            if !legacyPins.isEmpty, store.acceptsLegacyPins || store.spaces.allSatisfy({ $0.pinned.isEmpty }) {
                var pinned = store.spaces[0].pinned
                let known = Set(pinned.flatMap(\.tabs).compactMap(\.url))
                for pin in legacyPins {
                    // Same rules as the session: no image bytes or temporary URLs.
                    let url = Self.persistableURL(pin.url)
                    if let url, known.contains(url) { continue }
                    let temporary = ["data", "blob"].contains(pin.url?.scheme?.lowercased() ?? "")
                    pinned.append(.tab(SidebarTabRecord(id: pin.id, title: temporary ? L10n.string("New Tab") : pin.title, url: url)))
                }
                store.setPinned(pinned, in: store.spaces[0].id, origin: nil)
            }
        }
        rebuildPinnedFromStore()

        if let initialTab {
            initialTab.owner = self
            initialTab.isPinned = false
            initialTab.spaceID = activeSpaceID
            tabs.append(initialTab)
            layouts[activeSpaceID, default: SpaceLayout()].regular.append(.tab(initialTab.id))
            selectedTabID = initialTab.id
        } else if let session {
            if let spaces = session.spaces {
                for saved in spaces {
                    // A space that no longer exists (deleted elsewhere, or a lost spaces
                    // file) hands its tabs to the default space instead of dropping them.
                    let known = store.space(saved.id) != nil
                    let space = known ? saved.id : store.defaultSpaceID
                    if !known, session.activeSpaceID == saved.id { activeSpaceID = space }
                    var layout = layouts[space] ?? SpaceLayout()
                    for node in saved.regular {
                        switch node {
                        case .tab(let record):
                            if let tab = makeRestoredTab(record, space: space) { layout.regular.append(.tab(tab.id)) }
                        case .group(let record):
                            let ids = record.tabs.compactMap { makeRestoredTab($0, space: space)?.id }
                            layout.regular.append(.group(TabGroup(id: record.id, name: record.name, icon: record.icon,
                                                                  isExpanded: record.isExpanded, tabIDs: ids)))
                        }
                    }
                    layouts[space] = layout
                    if let selected = saved.selectedTabID, known || selectionBySpace[space] == nil { selectionBySpace[space] = selected }
                }
            } else {
                let space = store.spaces[0].id
                for record in session.tabs where !record.isPinned {
                    if let tab = makeRestoredTab(SidebarTabRecord(id: record.id, title: record.title, url: record.url), space: space) {
                        layouts[space, default: SpaceLayout()].regular.append(.tab(tab.id))
                    }
                }
                activeSpaceID = space
            }
            if let selected = session.selectedTabID, tab(selected)?.spaceID == activeSpaceID {
                selectedTabID = selected
            } else {
                selectedTabID = preferredSelection(in: activeSpaceID)
            }
        }
        // A new window, or a session with nothing left in it, starts with one page.
        if initialTab == nil, session == nil || tabs.isEmpty {
            let tab = startWithBlankTab
                ? BrowserTab(owner: self)
                : BrowserTab(title: "Apple", url: URL(string: "https://www.apple.com"), owner: self)
            add(tab, to: activeSpaceID)
            selectedTabID = tab.id
        }
        isRestoring = false
        store.finishLegacyMigration()
        initialTab?.finishNativeLifecycleTransfer()
        synchronizeChromiumLifecycleStates()
        if loadSelectedTab, initialTab == nil { selectedTab?.loadIfNeeded() }
        storeObserver = NotificationCenter.default.addObserver(forName: .nousSpacesDidChange, object: nil, queue: .main) { [weak self] note in
            let origin = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated {
                guard let self, origin != ObjectIdentifier(self) else { return }
                self.storeDidChange()
            }
        }
    }

    /// `tabs` reads in sidebar order (space by space: pins, then the list), so
    /// automation, ⌘1–9 and the saved session agree with what is on screen.
    private func orderTabsLikeSidebar() {
        let order = spaceStore.spaces.flatMap { layouts[$0.id]?.allTabIDs ?? [] }
        guard tabs.map(\.id) != order else { return }
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let ordered = tabs.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.id] ?? order.count + lhs.offset
            let right = rank[rhs.element.id] ?? order.count + rhs.offset
            return left < right
        }.map(\.element)
        if ordered.map(\.id) != tabs.map(\.id) { tabs = ordered }
    }

    private func makeRestoredTab(_ record: SidebarTabRecord, space: UUID) -> BrowserTab? {
        guard tab(record.id) == nil else { return nil }
        let tab = BrowserTab(id: record.id, title: record.title, url: record.url, owner: self)
        tab.spaceID = space
        tabs.append(tab)
        return tab
    }

    private func add(_ tab: BrowserTab, to space: UUID, after anchor: UUID? = nil) {
        tab.spaceID = space
        tab.isPinned = false
        tabs.append(tab)
        var layout = layouts[space] ?? SpaceLayout()
        if let anchor, let location = layout.location(of: anchor) {
            if location.section == .regular, let groupID = location.groupID, let group = layout.group(groupID),
               let index = group.tabIDs.firstIndex(of: anchor) {
                layout.insertTab(tab.id, section: .regular, groupID: groupID, index: index + 1)
            } else if location.section == .regular, let index = layout.regular.firstIndex(of: .tab(anchor)) {
                layout.regular.insert(.tab(tab.id), at: index + 1)
            } else {
                // Links from a pinned page start the ordinary list.
                layout.regular.insert(.tab(tab.id), at: 0)
            }
        } else {
            layout.regular.append(.tab(tab.id))
        }
        layouts[space] = layout
    }

    private func preferredSelection(in space: UUID) -> UUID? {
        let layout = layout(for: space)
        if let remembered = selectionBySpace[space], layout.contains(tab: remembered) { return remembered }
        return layout.regularTabIDs.last ?? nil
    }

    // MARK: Tabs

    func newTab(url: URL? = nil) {
        guard !isShutDown, !windowCloseApproved else { return }
        let tab = BrowserTab(url: url, owner: self)
        add(tab, to: activeSpaceID)
        selectedTabID = tab.id
        tab.loadIfNeeded()
        persistSession()
    }

    @discardableResult
    func openLinkInNewTab(_ url: URL, after sourceID: UUID, activate: Bool = true) -> BrowserTab? {
        guard Self.canOpenExternalURL(url) else { return nil }
        return insertLinkTab(url, after: sourceID, activate: activate)
    }

    /// Library and capture pages: reuse an open tab showing the same page.
    func openNativePage(_ page: NativePage) {
        guard !isShutDown, !windowCloseApproved else { return }
        if let existing = visibleTabs.first(where: { $0.nativePage == page }) {
            selectTab(existing.id)
            return
        }
        // One Library tab per space; it switches to the requested section.
        if page.isLibrary, let library = visibleTabs.first(where: { $0.nativePage?.isLibrary == true }) {
            library.load(page.url)
            selectTab(library.id)
            return
        }
        if let selectedTab, !selectedTab.hasWebContent, selectedTab.url == nil {
            selectedTab.load(page.url)
        } else {
            newTab(url: page.url)
        }
        persistSession()
    }

    private func insertLinkTab(_ url: URL, after sourceID: UUID, activate: Bool = true) -> BrowserTab? {
        guard !windowCloseApproved else { return nil }
        guard !isShutDown, let source = tab(sourceID) else { return nil }
        let tab = BrowserTab(url: url, owner: self)
        prepareChromiumDestination(tab, source: source, activate: activate)
        add(tab, to: source.spaceID ?? activeSpaceID, after: sourceID)
        if activate { selectedTabID = tab.id }
        // No selection didSet runs for a new background tab. Supply its real
        // lifecycle state before loadIfNeeded can create the native browser.
        if !activate { synchronizeChromiumLifecycleState(for: tab) }
        tab.loadIfNeeded()
        persistSession()
        return tab
    }

    func openLinkInNewWindow(_ url: URL, from sourceID: UUID? = nil) {
        guard !isShutDown, Self.canOpenExternalURL(url),
              sourceID == nil || tabs.contains(where: { $0.id == sourceID }) else { return }
        onOpenLinkInNewWindow?(url)
    }

    /// The bridge emits this only for a user's image context-menu command.
    /// Keep page-owned blobs/data separate from Launch Services and MCP input.
    func openChromiumImage(_ url: URL, after sourceID: UUID, inNewWindow: Bool, activate: Bool = true) {
        guard !isShutDown, BrowserNativeImageURL.allows(url),
              tabs.contains(where: { $0.id == sourceID }) else { return }
        if inNewWindow { onOpenChromiumImageWindow?(url) }
        else { _ = insertLinkTab(url, after: sourceID, activate: activate) }
    }

    /// A transfer changes ownership without closing, pausing or reloading the page.
    /// Pinned tabs are shared by every window, so only ordinary tabs move.
    func takeTabForTransfer(_ id: UUID) -> BrowserTab? {
        guard windowCloseTransactionID == nil, !windowCloseApproved, !pendingTabCloses.contains(id) else { return nil }
        guard !isShutDown, let index = tabs.firstIndex(where: { $0.id == id }), !tabs[index].isPinned,
              tabs[index].webView.fullscreenState == .notInFullscreen else { return nil }
        // Protect a previously background tab before detaching it. Ownership
        // can be nil while a new window is constructed or a transfer rolls back.
        tabs[index].prepareForNativeLifecycleTransfer()
        let siblings = activeLayout.regularTabIDs
        let previousIndex = siblings.firstIndex(of: id) ?? 0
        let tab = tabs.remove(at: index)
        if let space = tab.spaceID { layouts[space]?.removeTab(id) }
        tab.owner = nil
        tab.webView.removeFromSuperview()
        if selectedTabID == id {
            // The neighbour below takes over, as when closing a tab.
            let remaining = activeLayout.regularTabIDs
            selectedTabID = remaining.isEmpty ? preferredSelection(in: activeSpaceID)
                : remaining[min(previousIndex, remaining.count - 1)]
            selectedTab?.loadIfNeeded()
        }
        return tab
    }

    func canAdoptTransferredTab(withID id: UUID) -> Bool {
        guard windowCloseTransactionID == nil, !windowCloseApproved else { return false }
        return !isShutDown && !tabs.contains(where: { $0.id == id })
    }

    /// `index` is a slot in the active space's ordinary list.
    @discardableResult
    func adoptTransferredTab(_ tab: BrowserTab, at index: Int) -> Bool {
        guard tab.owner == nil, canAdoptTransferredTab(withID: tab.id) else { return false }
        tab.owner = self
        tab.spaceID = activeSpaceID
        tab.isPinned = false
        tabs.append(tab)
        layouts[activeSpaceID, default: SpaceLayout()].update(.regular) { nodes in
            nodes.insert(.tab(tab.id), at: min(max(0, index), nodes.count))
        }
        selectedTabID = tab.id
        tab.finishNativeLifecycleTransfer()
        persistSession()
        return true
    }

    func selectTab(_ id: UUID) {
        guard let tab = tab(id) else { return }
        if let space = tab.spaceID, space != activeSpaceID {
            activeSpaceID = space
            spaceStore.noteActive(space)
        }
        selectedTabID = id
        tab.loadIfNeeded()
        persistSession()
    }

    func duplicateTab(_ id: UUID) {
        guard let source = tab(id) else { return }
        let duplicate = BrowserTab(title: source.title, url: source.url, owner: self)
        duplicate.title = source.title
        // A duplicated pinned page is an ordinary tab; others sit beside their source.
        add(duplicate, to: source.spaceID ?? activeSpaceID, after: id)
        selectedTabID = duplicate.id
        duplicate.loadIfNeeded()
        persistSession()
    }

    func togglePin(_ id: UUID) {
        guard let tab = tab(id), let space = tab.spaceID, var layout = layouts[space],
              let location = layout.location(of: id) else { return }
        layout.removeTab(id)
        if location.section == .pinned { layout.regular.insert(.tab(id), at: 0) }
        else { layout.pinned.append(.tab(id)) }
        applyLayout(layout, to: space, pinnedChanged: true)
    }

    /// Accessibility and automation: one step within the tab's own list.
    func moveTab(_ id: UUID, by step: Int) {
        guard let space = tab(id)?.spaceID, let layout = layouts[space], let location = layout.location(of: id) else { return }
        let siblings: [UUID] = location.groupID.flatMap { layout.group($0)?.tabIDs }
            ?? layout.nodes(location.section).map(\.id)
        guard let index = siblings.firstIndex(of: id) else { return }
        let destination = index + step
        guard siblings.indices.contains(destination) else { return }
        move(.tab(id), to: SidebarDropTarget(section: location.section, groupID: location.groupID, index: destination))
    }

    func canMoveTab(_ id: UUID, by step: Int) -> Bool {
        guard let space = tab(id)?.spaceID, let layout = layouts[space], let location = layout.location(of: id) else { return false }
        let siblings: [UUID] = location.groupID.flatMap { layout.group($0)?.tabIDs }
            ?? layout.nodes(location.section).map(\.id)
        guard let index = siblings.firstIndex(of: id) else { return false }
        return siblings.indices.contains(index + step)
    }

    /// Automation: move a tab so it ends up at `destination` in the visible order.
    func moveTab(_ id: UUID, to destination: Int) {
        let others = visibleTabs.map(\.id).filter { $0 != id }
        guard let layout = layouts[activeSpaceID], layout.contains(tab: id), !others.isEmpty, destination >= 0 else { return }
        var without = layout
        _ = without.removeTab(id)
        // Before the first tab, or after the tab that will precede it.
        let before = destination == 0
        let anchorID = before ? others[0] : others[min(destination - 1, others.count - 1)]
        guard let anchor = without.location(of: anchorID), let own = layout.location(of: id)?.section else { return }
        // Automation reorders within a list (pinning is its own command): a
        // destination across the pins/list boundary clamps to that edge.
        guard anchor.section == own else {
            let index = own == .regular ? 0 : without.pinned.count
            move(.tab(id), to: SidebarDropTarget(section: own, groupID: nil, index: index))
            return
        }
        let siblings: [UUID] = anchor.groupID.flatMap { without.group($0)?.tabIDs } ?? without.nodes(anchor.section).map(\.id)
        let index = (siblings.firstIndex(of: anchorID) ?? 0) + (before ? 0 : 1)
        move(.tab(id), to: SidebarDropTarget(section: anchor.section, groupID: anchor.groupID, index: index))
    }

    /// The single entry point for drag and drop in the sidebar.
    func move(_ item: SidebarItemRef, to target: SidebarDropTarget, in space: UUID? = nil) {
        let space = space ?? activeSpaceID
        guard let layout = layouts[space] else { return }
        let before = layout
        let after = layout.moving(item, to: target)
        guard after != before else { return }
        applyLayout(after, to: space, pinnedChanged: after.pinned != before.pinned)
    }

    func moveTab(_ id: UUID, toSpace destination: UUID) {
        guard let tab = tab(id), let source = tab.spaceID, source != destination,
              spaceStore.space(destination) != nil, var sourceLayout = layouts[source] else { return }
        let wasPinned = sourceLayout.location(of: id)?.section == .pinned
        sourceLayout.removeTab(id)
        var destinationLayout = layouts[destination] ?? SpaceLayout()
        destinationLayout.regular.append(.tab(id))
        tab.spaceID = destination
        if selectedTabID == id { selectedTabID = preferredSelection(in: source) }
        applyLayout(sourceLayout, to: source, pinnedChanged: wasPinned)
        applyLayout(destinationLayout, to: destination, pinnedChanged: false)
    }

    private func applyLayout(_ layout: SpaceLayout, to space: UUID, pinnedChanged: Bool) {
        var layout = layout
        // Pinned tabs show as tiles before pinned folders; keep the array in that order.
        layout.pinned = layout.pinned.filter { $0.group == nil } + layout.pinned.filter { $0.group != nil }
        layouts[space] = layout
        let pinned = Set(layout.pinnedTabIDs)
        for id in layout.allTabIDs {
            guard let tab = tab(id) else { continue }
            let isPinned = pinned.contains(id)
            if tab.isPinned != isPinned { tab.isPinned = isPinned }
        }
        if pinnedChanged { publishPinned(space) }
        persistSession()
    }

    // MARK: Folders

    @discardableResult
    func newGroup(containing ids: [UUID] = [], section: SidebarSection = .regular, name: String? = nil) -> UUID? {
        let space = ids.first.flatMap { tab($0)?.spaceID } ?? activeSpaceID
        guard var layout = layouts[space] else { return nil }
        let members = ids.filter { layout.contains(tab: $0) }
        let section = members.first.flatMap { layout.location(of: $0)?.section } ?? section
        // The folder takes the place of its first tab.
        let anchor = members.first.flatMap { id in layout.nodes(section).firstIndex { $0.tabIDs.contains(id) } }
        for id in members { layout.removeTab(id) }
        let group = TabGroup(name: name ?? L10n.string("New Folder"), tabIDs: members)
        layout.update(section) { nodes in nodes.insert(.group(group), at: min(anchor ?? nodes.count, nodes.count)) }
        applyLayout(layout, to: space, pinnedChanged: section == .pinned || layout.pinned != layouts[space]?.pinned)
        return group.id
    }

    func updateGroup(_ id: UUID, name: String? = nil, icon: String? = nil, isExpanded: Bool? = nil) {
        guard let space = spaceID(ofGroup: id), var layout = layouts[space] else { return }
        layout.updateGroup(id) { group in
            if let name {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { group.name = trimmed }
            }
            if let icon { group.icon = icon }
            if let isExpanded { group.isExpanded = isExpanded }
        }
        applyLayout(layout, to: space, pinnedChanged: layout.section(ofGroup: id) == .pinned)
    }

    func toggleGroupPinned(_ id: UUID) {
        guard let space = spaceID(ofGroup: id), var layout = layouts[space],
              let (group, section, _) = layout.removeGroup(id) else { return }
        if section == .pinned { layout.regular.insert(.group(group), at: 0) }
        else { layout.pinned.append(.group(group)) }
        applyLayout(layout, to: space, pinnedChanged: true)
    }

    /// The folder's tabs take its place.
    func ungroup(_ id: UUID) {
        guard let space = spaceID(ofGroup: id), var layout = layouts[space],
              let (group, section, index) = layout.removeGroup(id) else { return }
        layout.update(section) { nodes in nodes.insert(contentsOf: group.tabIDs.map(SidebarNode.tab), at: min(index, nodes.count)) }
        applyLayout(layout, to: space, pinnedChanged: section == .pinned)
    }

    /// Closes the folder's pages and removes the folder.
    func closeGroup(_ id: UUID) {
        guard let space = spaceID(ofGroup: id), var layout = layouts[space],
              let (group, section, _) = layout.removeGroup(id) else { return }
        if section == .pinned {
            for tabID in group.tabIDs { discardTab(tabID) }
            applyLayout(layout, to: space, pinnedChanged: true)
            return
        }
        layout.update(.regular) { nodes in nodes.append(contentsOf: group.tabIDs.map(SidebarNode.tab)) }
        applyLayout(layout, to: space, pinnedChanged: false)
        for tabID in group.tabIDs { closeTab(tabID) }
    }

    private func spaceID(ofGroup id: UUID) -> UUID? {
        layouts.first { $0.value.groups.contains { $0.id == id } }?.key
    }

    // MARK: Spaces

    func switchSpace(to id: UUID) {
        guard id != activeSpaceID, spaceStore.space(id) != nil else { return }
        activeSpaceID = id
        spaceStore.noteActive(id)
        selectedTabID = preferredSelection(in: id)
        selectedTab?.loadIfNeeded()
        persistSession()
    }

    func switchSpace(by offset: Int) {
        let ids = spaces.map(\.id)
        guard let index = ids.firstIndex(of: activeSpaceID) else { return }
        let next = index + offset
        guard ids.indices.contains(next) else { return }
        switchSpace(to: ids[next])
    }

    func newSpace() {
        let id = spaceStore.addSpace(origin: self)
        layouts[id] = SpaceLayout()
        switchSpace(to: id)
    }

    /// Closes the space's ordinary tabs in this window; other windows discard theirs.
    func deleteSpace(_ id: UUID) {
        guard spaces.count > 1 else { return }
        if activeSpaceID == id {
            let fallback = spaces.first { $0.id != id }!.id
            switchSpace(to: fallback)
        }
        spaceStore.removeSpace(id)
        storeDidChange()
    }

    // MARK: Shared pins

    /// Mirrors the store's pinned items as live tabs; ordinary tabs stay as they are.
    private func rebuildPinnedFromStore() {
        let records = spaceStore.spaces
        let ids = Set(records.map(\.id))
        for (space, layout) in layouts where !ids.contains(space) {
            for id in layout.allTabIDs { discardTab(id, updatingLayout: false) }
            layouts[space] = nil
        }
        for record in records {
            var layout = layouts[record.id] ?? SpaceLayout()
            var desired: [SidebarNode] = []
            for node in record.pinned {
                switch node {
                case .tab(let pin):
                    desired.append(.tab(pinnedTab(pin, space: record.id).id))
                case .group(let group):
                    desired.append(.group(TabGroup(id: group.id, name: group.name, icon: group.icon, isExpanded: group.isExpanded,
                                                   tabIDs: group.tabs.map { pinnedTab($0, space: record.id).id })))
                }
            }
            let desiredIDs = Set(desired.flatMap(\.tabIDs))
            for id in layout.pinnedTabIDs where !desiredIDs.contains(id) && !layoutContainsElsewhere(id, except: record.id) {
                discardTab(id, updatingLayout: false)
            }
            layout.regular = layout.regular.compactMap { node in
                switch node {
                case .tab(let id): return desiredIDs.contains(id) ? nil : node
                case .group(var group):
                    group.tabIDs.removeAll { desiredIDs.contains($0) }
                    return .group(group)
                }
            }
            layout.pinned = desired
            layouts[record.id] = layout
        }
        for tab in tabs {
            let pinned = tab.spaceID.map { layouts[$0]?.pinnedTabIDs.contains(tab.id) ?? false } ?? false
            if tab.isPinned != pinned { tab.isPinned = pinned }
        }
    }

    private func layoutContainsElsewhere(_ id: UUID, except space: UUID) -> Bool {
        layouts.contains { $0.key != space && $0.value.contains(tab: id) }
    }

    private func pinnedTab(_ record: SidebarTabRecord, space: UUID) -> BrowserTab {
        if let existing = tab(record.id) {
            if let previous = existing.spaceID, previous != space { layouts[previous]?.removeTab(record.id) }
            existing.spaceID = space
            return existing
        }
        let tab = BrowserTab(id: record.id, title: record.title, url: record.url, isPinned: true, owner: self)
        tab.spaceID = space
        tabs.append(tab)
        if !isRestoring { synchronizeChromiumLifecycleState(for: tab) }
        return tab
    }

    private func storeDidChange() {
        guard !isShutDown else { return }
        rebuildPinnedFromStore()
        if spaceStore.space(activeSpaceID) == nil {
            activeSpaceID = spaceStore.defaultSpaceID
            selectedTabID = preferredSelection(in: activeSpaceID)
        } else if let selectedTabID, tab(selectedTabID) == nil {
            self.selectedTabID = preferredSelection(in: activeSpaceID)
        }
        persistSession()
    }

    private func publishPinned(_ space: UUID) {
        guard let layout = layouts[space] else { return }
        let existing = Dictionary(spaceStore.space(space)?.pinned.flatMap(\.tabs).map { ($0.id, $0) } ?? [],
                                  uniquingKeysWith: { first, _ in first })
        func record(_ id: UUID) -> SidebarTabRecord? {
            guard let tab = tab(id) else { return existing[id] }
            // A pin keeps the address it was pinned with; closing it returns there.
            let url = existing[id]?.url ?? Self.persistableURL(tab.url)
            return SidebarTabRecord(id: id, title: tab.displayTitle, url: url)
        }
        let nodes: [SidebarNodeRecord] = layout.pinned.compactMap { node in
            switch node {
            case .tab(let id): record(id).map(SidebarNodeRecord.tab)
            case .group(let group):
                .group(SidebarGroupRecord(id: group.id, name: group.name, icon: group.icon, isExpanded: group.isExpanded,
                                          tabs: group.tabIDs.compactMap(record)))
            }
        }
        spaceStore.setPinned(nodes, in: space, origin: self)
    }

    /// Removes a page without beforeunload: a pin removed in another window.
    private func discardTab(_ id: UUID, updatingLayout: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        if updatingLayout, let space = tab.spaceID { layouts[space]?.removeTab(id) }
        pendingTabCloses.remove(id)
        tab.shutdown()
        if selectedTabID == id { selectedTabID = nil }
    }

    // MARK: Closing

    func closeTab(_ id: UUID) {
        requestTabClose(id) { _ in }
    }

    /// Only an ordinary tab can be a window's last page; pins outlive windows.
    private func isLastPage(_ id: UUID) -> Bool {
        tabs.count == 1 && tabs[0].id == id && !tabs[0].isPinned
    }

    func requestTabClose(_ id: UUID, completion: @escaping (Bool) -> Void) {
        guard !isShutDown, !windowCloseApproved, windowCloseTransactionID == nil,
              let tab = tabs.first(where: { $0.id == id }) else { completion(false); return }
        if isLastPage(id), let onLastChromiumTabClose {
            onLastChromiumTabClose(completion)
            return
        }
        guard pendingTabCloses.insert(id).inserted else { completion(false); return }
        tab.requestClose { [weak self, weak tab] accepted in
            guard let self else { completion(accepted); return }
            self.pendingTabCloses.remove(id)
            if accepted, let tab, tab.isOwned(by: self), !self.isShutDown {
                self.chromiumTabDidClose(id)
            }
            completion(accepted)
        }
    }

    /// Handles both an approved user close and native window.close(). The host
    /// stays in the model until Chromium actually finishes closing it.
    func chromiumTabDidClose(_ id: UUID) {
        guard !isShutDown, tabs.contains(where: { $0.id == id }) else { return }
        if windowCloseTransactionID != nil {
            closedWindowTabIDs.insert(id)
            return
        }
        guard !windowCloseApproved else { return }
        pendingTabCloses.remove(id)
        if isLastPage(id), let onLastTabClosed {
            onLastTabClosed()
            return
        }
        removeClosedChromiumTabs([id])
    }

    /// One-window close uses the same reversible transaction as app-wide quit.
    func requestWindowClose(completion: @escaping (Bool) -> Void) {
        guard !isShutDown, !windowCloseApproved else { completion(true); return }
        guard windowCloseTransactionID == nil else { completion(false); return }
        let transactionID = UUID()
        let transaction = ChromiumCloseTransaction(id: transactionID, targets: { [weak self] in
            self?.targetsForWindowClose(transactionID)
        }, willCommit: { [weak self] in
            self?.approveWindowClose(transactionID)
        }, completion: { [weak self] accepted in
            self?.finishWindowClose(transactionID, committed: accepted)
            self?.windowCloseTransaction = nil
            completion(accepted)
        })
        windowCloseTransaction = transaction
        transaction.start()
    }

    /// Acquires this model for a local or cross-window transaction. Already
    /// requested single-tab closes must finish first; they cannot be rolled back.
    func targetsForWindowClose(_ transactionID: UUID) -> [ChromiumCloseTransaction.Target]? {
        guard !isShutDown, !windowCloseApproved, pendingTabCloses.isEmpty,
              windowCloseTransactionID == nil || windowCloseTransactionID == transactionID else { return nil }
        if windowCloseTransactionID == nil { closedWindowTabIDs.removeAll() }
        windowCloseTransactionID = transactionID
        return tabs.filter { !closedWindowTabIDs.contains($0.id) }.map { tab in
            .init(id: tab.id, prepare: { [weak self, weak tab] answer in
                guard let self, let tab, tab.isOwned(by: self) else { answer(false); return }
                tab.webView.prepareClose { [weak self, weak tab] accepted in
                    if !accepted, let self, let tab, tab.isOwned(by: self) { self.selectTab(tab.id) }
                    answer(accepted)
                }
            }, validate: { [weak self, weak tab] in
                guard let self, let tab, tab.isOwned(by: self) else { return false }
                return tab.webView.validatePreparedClose()
            }, cancel: { [weak tab] in tab?.webView.cancelPreparedClose() },
            commit: { [weak self, weak tab] answer in
                guard let self, let tab, tab.isOwned(by: self) else { answer(false); return }
                tab.webView.commitPreparedClose { [weak self, weak tab] closed in
                    if closed, let self, let tab, tab.isOwned(by: self) { self.chromiumTabDidClose(tab.id) }
                    answer(closed)
                }
            })
        }
    }

    func approveWindowClose(_ transactionID: UUID) {
        guard windowCloseTransactionID == transactionID else { return }
        windowCloseApproved = true
    }

    func finishWindowClose(_ transactionID: UUID, committed: Bool) {
        guard windowCloseTransactionID == transactionID else { return }
        windowCloseTransactionID = nil
        windowCloseApproved = committed
        let independentlyClosed = closedWindowTabIDs
        closedWindowTabIDs.removeAll()
        // window.close() is an independent page action, not a destructive
        // preflight. Remove only those native pages if the transaction cancels.
        if !committed { removeClosedChromiumTabs(independentlyClosed) }
    }

    /// Ordinary tabs are removed. A closed pin stays in place, unloaded and back
    /// at the address it was pinned with.
    private func removeClosedChromiumTabs(_ ids: Set<UUID>) {
        let removed = tabs.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        let wasSelected = selectedTabID.map(ids.contains) ?? false
        let siblings = activeLayout.regularTabIDs
        let previousIndex = selectedTabID.flatMap { siblings.firstIndex(of: $0) } ?? 0
        for tab in removed {
            pendingTabCloses.remove(tab.id)
            if tab.isPinned, let space = tab.spaceID {
                let pin = spaceStore.space(space)?.pinned.flatMap(\.tabs).first { $0.id == tab.id }
                let fresh = BrowserTab(id: tab.id, title: pin?.title ?? tab.title, url: pin?.url ?? tab.url,
                                       isPinned: true, owner: self)
                fresh.spaceID = space
                tab.shutdown()
                if let index = tabs.firstIndex(where: { $0 === tab }) { tabs[index] = fresh }
                synchronizeChromiumLifecycleState(for: fresh)
                continue
            }
            closedTabs.append(.init(id: tab.id, title: tab.title, url: tab.url, isPinned: false))
            if let space = tab.spaceID { layouts[space]?.removeTab(tab.id) }
            tabs.removeAll { $0 === tab }
            tab.shutdown()
        }
        if closedTabs.count > 20 { closedTabs.removeFirst(closedTabs.count - 20) }
        if tabs.isEmpty { newTab() }
        else if wasSelected {
            let remaining = activeLayout.regularTabIDs
            selectedTabID = remaining.isEmpty ? nil : remaining[min(previousIndex, remaining.count - 1)]
            selectedTab?.loadIfNeeded()
        }
        persistSession()
    }

    // MARK: Navigation

    func navigate(_ input: String, searchEngine: BrowserSearchEngine = .google) {
        guard let url = Self.normalizeAddress(input, searchEngine: searchEngine) else { return }
        if selectedTab == nil { newTab(url: url) }
        else { selectedTab?.load(url) }
        persistSession()
    }

    /// Launch Services may deliver both website URLs and HTML documents.
    /// Other files and arbitrary application schemes are outside this handler.
    nonisolated static func canOpenExternalURL(_ url: URL) -> Bool {
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return !(url.host ?? "").isEmpty
        }
        return url.isFileURL && !url.hasDirectoryPath
            && ["html", "htm", "xhtml"].contains(url.pathExtension.lowercased())
    }

    /// Safari's explicit HTTPS wrapper still represents a website. Resolve
    /// that known format internally instead of sending it to Launch Services.
    nonisolated static func unwrappedSafariWebsite(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "x-safari-https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        components.scheme = "https"
        return components.url
    }

    /// Supports URL entry, localhost development addresses, and ordinary search queries.
    /// Active-content and file schemes cannot be entered through the address field.
    nonisolated static func normalizeAddress(_ input: String, searchEngine: BrowserSearchEngine = .google) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // Explicit address entry may inspect Chromium's own diagnostics. These
        // are not external URL handlers or a permission for websites to open
        // privileged browser pages.
        if let components = URLComponents(string: text), components.scheme?.lowercased() == "chrome",
           ["version", "gpu", "discards"].contains(components.host?.lowercased() ?? ""),
           components.user == nil, components.password == nil, components.port == nil,
           components.path.isEmpty || components.path == "/",
           components.query == nil, components.fragment == nil {
            return components.url
        }
        if let url = URL(string: text), let page = NativePage(url: url) { return page.url }
        if let url = BrowserAddressInput.websiteURL(for: text) { return url }
        let lower = text.lowercased()
        if text.contains("://") || lower.hasPrefix("javascript:") || lower.hasPrefix("data:") || lower.hasPrefix("file:") {
            return nil
        }
        return searchEngine.searchURL(query: text)
    }

    func goBack() { selectedTab?.webView.goBack() }
    func goForward() { selectedTab?.webView.goForward() }
    func reload(bypassingCache: Bool = false) {
        guard let tab = selectedTab, tab.hasWebContent else { return }
        let failed = tab.errorDescription != nil
        tab.errorDescription = nil
        if failed || tab.webView.url == nil {
            guard let url = tab.url else { return }
            tab.load(url, cachePolicy: bypassingCache ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy)
        } else if bypassingCache {
            // Revalidate with the origin without clearing cookies or website data.
            tab.webView.reloadFromOrigin()
        } else { tab.webView.reload() }
    }
    func stopLoading() { selectedTab?.webView.stopLoading() }
    /// Cmd-/ switches the visible presentation. From a fully hidden window it
    /// explicitly reveals the expanded sidebar, rather than requiring a second
    /// shortcut before the list becomes available.
    func toggleSidebar() {
        if isSidebarVisible { isSidebarCompact.toggle() }
        else {
            isSidebarCompact = false
            isSidebarVisible = true
        }
    }

    /// Cmd-. hides/restores the sidebar without changing its remembered width
    /// or whether it was expanded or compact.
    func toggleSidebarHidden() { isSidebarVisible.toggle() }

    private static let zoomLevels: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]

    func zoomIn() {
        guard let tab = selectedTab, tab.hasWebContent else { return }
        tab.webView.pageZoom = Self.zoomLevels.first { $0 > tab.webView.pageZoom + 0.001 } ?? Self.zoomLevels.last!
    }

    func zoomOut() {
        guard let tab = selectedTab, tab.hasWebContent else { return }
        tab.webView.pageZoom = Self.zoomLevels.last { $0 < tab.webView.pageZoom - 0.001 } ?? Self.zoomLevels.first!
    }

    func resetZoom() {
        guard let tab = selectedTab, tab.hasWebContent else { return }
        tab.webView.pageZoom = 1
    }

    func resizeSidebar(to width: Double) {
        let width = SidebarSizing.clampedWidth(width)
        guard sidebarWidth != width else { return }
        sidebarWidth = width
        scheduleSave()
    }

    func resetSidebarWidth() { resizeSidebar(to: SidebarSizing.defaultWidth) }

    func restoreClosedTab() {
        guard let saved = closedTabs.popLast() else { return }
        let tab = BrowserTab(id: self.tab(saved.id) == nil ? saved.id : UUID(), title: saved.title, url: saved.url, owner: self)
        add(tab, to: activeSpaceID)
        selectedTabID = tab.id
        tab.loadIfNeeded()
        persistSession()
    }

    func selectNextTab(backward: Bool = false) {
        let order = visibleTabs.map(\.id)
        guard !order.isEmpty else { return }
        let current = selectedTabID.flatMap { order.firstIndex(of: $0) } ?? (backward ? 0 : order.count - 1)
        let next = (current + (backward ? -1 : 1) + order.count) % order.count
        selectTab(order[next])
    }

    /// Browser convention: 1–8 select a position; 9 always selects the last tab.
    func selectTab(number: Int) {
        let order = visibleTabs.map(\.id)
        guard (1...9).contains(number), !order.isEmpty else { return }
        let index = number == 9 ? order.count - 1 : number - 1
        guard order.indices.contains(index) else { return }
        selectTab(order[index])
    }

    // MARK: Persistence

    func persistSession() {
        guard !isRestoring, !isShutDown else { return }
        do { try persistForRestart() }
        catch { NSLog("Nous Browser: Could not save tab session: %@", error.localizedDescription) }
    }

    private func sessionRecord(_ id: UUID) -> SidebarTabRecord? {
        guard let tab = tab(id) else { return nil }
        // Image documents can include their data URL in the title too.
        // Preserve the slot and selection, without storing image bytes.
        let temporary = ["data", "blob"].contains(tab.url?.scheme?.lowercased() ?? "")
        return SidebarTabRecord(id: id, title: temporary ? L10n.string("New Tab") : tab.title, url: Self.persistableURL(tab.url))
    }

    /// A restart must be canceled if the live session cannot be saved. Ordinary
    /// autosaves retain their best-effort wrapper above; this path never reports
    /// success for an already shut-down or still-restoring model.
    func persistForRestart() throws {
        guard !isRestoring, !isShutDown else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: sessionURL.path])
        }
        saveTask?.cancel()
        // Pins and spaces are restored from the shared store; flush it with the session.
        spaceStore.save()
        let spaces: [BrowserSession.Space] = spaceStore.spaces.map { space in
            let layout = layouts[space.id] ?? SpaceLayout()
            let regular: [SidebarNodeRecord] = layout.regular.compactMap { node in
                switch node {
                case .tab(let id): sessionRecord(id).map(SidebarNodeRecord.tab)
                case .group(let group):
                    .group(SidebarGroupRecord(id: group.id, name: group.name, icon: group.icon,
                                              isExpanded: group.isExpanded, tabs: group.tabIDs.compactMap(sessionRecord)))
                }
            }
            return .init(id: space.id, regular: regular, selectedTabID: selectionBySpace[space.id])
        }
        let session = BrowserSession(
            tabs: spaces.flatMap { $0.regular.flatMap(\.tabs) }.map { .init(id: $0.id, title: $0.title, url: $0.url) },
            selectedTabID: selectedTabID,
            isSidebarVisible: isSidebarVisible,
            sidebarWidth: sidebarWidth,
            isSidebarCompact: isSidebarCompact,
            activeSpaceID: activeSpaceID,
            spaces: spaces
        )
        try FileManager.default.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(session)
        try data.write(to: sessionURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionURL.path)
        var titles: [UUID: String] = [:]
        for tab in tabs where tab.isPinned && tab.hasWebContent { titles[tab.id] = tab.title }
        spaceStore.refreshPinnedTitles(titles)
    }

    func scheduleSave() {
        guard !isRestoring, !isShutDown else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.persistSession()
        }
    }

    /// Closing a window preserves its final session without closing its tabs
    /// one by one or allowing late page observations to rewrite the snapshot.
    func shutdown() {
        guard !isShutDown else { return }
        persistSession()
        isShutDown = true
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = nil
        onLastTabClosed = nil
        onVisit = nil
        onPageTitleChanged = nil
        onOpenLinkInNewWindow = nil
        chromiumPresentationWindow = nil
        onCreateChromiumPopupWindow = nil
        onOpenChromiumImageWindow = nil
        onDownloadNotice = nil
        onLastChromiumTabClose = nil
        pendingTabCloses.removeAll()
        windowCloseTransaction?.cancel()
        windowCloseTransaction = nil
        windowCloseTransactionID = nil
        closedWindowTabIDs.removeAll()
        saveTask?.cancel()
        saveTask = nil
        tabs.forEach { $0.shutdown() }
    }

    func recordVisit(_ url: URL, title: String) {
        guard !isShutDown else { return }
        onVisit?(url, title)
    }

    func recordPageTitleChange(_ url: URL, title: String) {
        guard !isShutDown else { return }
        onPageTitleChanged?(url, title)
    }

    /// Strip credentials and non-restorable page-owned URLs before writing a
    /// session. The live tab is untouched; a temporary image restores blank.
    nonisolated static func persistableURL(_ url: URL?) -> URL? {
        if ["data", "blob"].contains(url?.scheme?.lowercased() ?? "") { return nil }
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.user = nil
        components.password = nil
        return components.url
    }

    /// Run inside the model transaction, before view rendering or asynchronous
    /// graph decisions. Protect the destination selection before releasing the
    /// former one; each window keeps its own selected page active.
    func synchronizeChromiumLifecycleStates() {
        guard !isShutDown else { return }
        if let selectedTab { synchronizeChromiumLifecycleState(for: selectedTab) }
        for tab in tabs where tab.id != selectedTabID {
            synchronizeChromiumLifecycleState(for: tab)
        }
    }

    func synchronizeChromiumLifecycleState(for tab: BrowserTab) {
        guard !isShutDown, tab.isOwned(by: self) else { return }
        tab.synchronizeNativeLifecycle(activeInWindow: tab.id == selectedTabID)
    }

    private func prepareChromiumDestination(_ tab: BrowserTab, source: BrowserTab, activate: Bool) {
        // Inherit a useful viewport without mounting or flashing the new page.
        // A selected source normally supplies the exact content dimensions.
        let sourceBounds = source.webView.bounds
        let fallback = chromiumPresentationWindow?.contentLayoutRect.size ?? NSSize(width: 800, height: 600)
        tab.webView.frame = NSRect(origin: .zero, size: sourceBounds.width > 0 && sourceBounds.height > 0 ? sourceBounds.size : fallback)
        tab.webView.isHidden = !activate
    }

    func openChromiumPopup(after sourceID: UUID, newWindow: Bool, activate: Bool = true) -> ChromiumPageView? {
        guard !isShutDown, !windowCloseApproved, let source = tab(sourceID) else { return nil }
        if newWindow {
            return onCreateChromiumPopupWindow?()?.webView
        }
        let tab = BrowserTab(owner: self, isPopup: true)
        prepareChromiumDestination(tab, source: source, activate: activate)
        add(tab, to: source.spaceID ?? activeSpaceID, after: sourceID)
        if activate { selectedTabID = tab.id }
        else { synchronizeChromiumLifecycleState(for: tab) }
        persistSession()
        return tab.webView
    }
}
