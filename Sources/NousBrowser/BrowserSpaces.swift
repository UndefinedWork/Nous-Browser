import Foundation
import Observation

// MARK: - Persisted records

/// A tab as written to disk. Live pages are never serialized, only their address.
nonisolated struct SidebarTabRecord: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var url: URL?
}

/// A folder of tabs. `icon` is an SF Symbol name or a single emoji.
nonisolated struct SidebarGroupRecord: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var icon: String
    var isExpanded: Bool
    var tabs: [SidebarTabRecord]
}

nonisolated enum SidebarNodeRecord: Codable, Equatable, Sendable {
    case tab(SidebarTabRecord)
    case group(SidebarGroupRecord)

    private enum CodingKeys: String, CodingKey { case tab, group }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let group = try container.decodeIfPresent(SidebarGroupRecord.self, forKey: .group) { self = .group(group) }
        else { self = .tab(try container.decode(SidebarTabRecord.self, forKey: .tab)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tab(let tab): try container.encode(tab, forKey: .tab)
        case .group(let group): try container.encode(group, forKey: .group)
        }
    }

    var tabs: [SidebarTabRecord] {
        switch self {
        case .tab(let tab): [tab]
        case .group(let group): group.tabs
        }
    }
}

/// Spaces and their pinned items belong to the whole browser, not one window:
/// closing every window keeps them. Ordinary tabs stay in each window session.
nonisolated struct BrowserSpaceRecord: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var icon: String
    var pinned: [SidebarNodeRecord]

    init(id: UUID = UUID(), name: String, icon: String, pinned: [SidebarNodeRecord] = []) {
        self.id = id
        self.name = name
        self.icon = icon
        self.pinned = pinned
    }
}

// MARK: - Runtime layout

nonisolated struct TabGroup: Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var icon: String
    var isExpanded: Bool
    var tabIDs: [UUID]

    init(id: UUID = UUID(), name: String, icon: String = TabGroup.defaultIcon, isExpanded: Bool = true, tabIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.icon = icon
        self.isExpanded = isExpanded
        self.tabIDs = tabIDs
    }

    static let defaultIcon = "folder"
}

nonisolated enum SidebarNode: Equatable, Identifiable, Sendable {
    case tab(UUID)
    case group(TabGroup)

    var id: UUID {
        switch self {
        case .tab(let id): id
        case .group(let group): group.id
        }
    }

    var tabIDs: [UUID] {
        switch self {
        case .tab(let id): [id]
        case .group(let group): group.tabIDs
        }
    }

    var group: TabGroup? {
        if case .group(let group) = self { return group }
        return nil
    }
}

nonisolated enum SidebarSection: Equatable, Hashable, Sendable { case pinned, regular }

/// The ids of one space in one window, in display order.
nonisolated struct SpaceLayout: Equatable, Sendable {
    var pinned: [SidebarNode] = []
    var regular: [SidebarNode] = []

    func nodes(_ section: SidebarSection) -> [SidebarNode] { section == .pinned ? pinned : regular }

    var allTabIDs: [UUID] { (pinned + regular).flatMap(\.tabIDs) }
    var pinnedTabIDs: [UUID] { pinned.flatMap(\.tabIDs) }
    var regularTabIDs: [UUID] { regular.flatMap(\.tabIDs) }
    var groups: [TabGroup] { (pinned + regular).compactMap(\.group) }

    func contains(tab id: UUID) -> Bool { allTabIDs.contains(id) }

    /// Where a tab sits: its section and, inside a folder, the folder id.
    func location(of tabID: UUID) -> (section: SidebarSection, groupID: UUID?)? {
        for section in [SidebarSection.pinned, .regular] {
            for node in nodes(section) {
                switch node {
                case .tab(let id) where id == tabID: return (section, nil)
                case .group(let group) where group.tabIDs.contains(tabID): return (section, group.id)
                default: continue
                }
            }
        }
        return nil
    }

    func section(ofGroup id: UUID) -> SidebarSection? {
        if pinned.contains(where: { $0.id == id }) { return .pinned }
        if regular.contains(where: { $0.id == id }) { return .regular }
        return nil
    }

    func group(_ id: UUID) -> TabGroup? { groups.first { $0.id == id } }

    mutating func update(_ section: SidebarSection, _ change: (inout [SidebarNode]) -> Void) {
        if section == .pinned { change(&pinned) } else { change(&regular) }
    }

    mutating func updateGroup(_ id: UUID, _ change: (inout TabGroup) -> Void) {
        for section in [SidebarSection.pinned, .regular] {
            update(section) { nodes in
                guard let index = nodes.firstIndex(where: { $0.id == id }), case .group(var group) = nodes[index] else { return }
                change(&group)
                nodes[index] = .group(group)
            }
        }
    }

    /// Removes a tab wherever it is. Empty folders are kept: the user made them.
    @discardableResult
    mutating func removeTab(_ tabID: UUID) -> Bool {
        var removed = false
        for section in [SidebarSection.pinned, .regular] {
            update(section) { nodes in
                if let index = nodes.firstIndex(of: .tab(tabID)) {
                    nodes.remove(at: index)
                    removed = true
                    return
                }
                for index in nodes.indices {
                    guard case .group(var group) = nodes[index], let position = group.tabIDs.firstIndex(of: tabID) else { continue }
                    group.tabIDs.remove(at: position)
                    nodes[index] = .group(group)
                    removed = true
                    return
                }
            }
        }
        return removed
    }

    @discardableResult
    mutating func removeGroup(_ id: UUID) -> (TabGroup, SidebarSection, Int)? {
        for section in [SidebarSection.pinned, .regular] {
            var result: (TabGroup, SidebarSection, Int)?
            update(section) { nodes in
                guard let index = nodes.firstIndex(where: { $0.id == id }), case .group(let group) = nodes[index] else { return }
                nodes.remove(at: index)
                result = (group, section, index)
            }
            if let result { return result }
        }
        return nil
    }

    /// Inserts at a top-level position, or inside a folder when `groupID` is set.
    mutating func insertTab(_ tabID: UUID, section: SidebarSection, groupID: UUID?, index: Int) {
        if let groupID, self.section(ofGroup: groupID) == section {
            updateGroup(groupID) { group in
                group.tabIDs.insert(tabID, at: min(max(0, index), group.tabIDs.count))
            }
            return
        }
        update(section) { nodes in nodes.insert(.tab(tabID), at: min(max(0, index), nodes.count)) }
    }
}

// MARK: - Store

extension Notification.Name {
    static let nousSpacesDidChange = Notification.Name("NousSpacesDidChange")
}

/// Shared by every window. Each window mirrors the pinned items into its own
/// live tabs and is told about changes made by another window.
@MainActor
@Observable
final class BrowserSpaceStore {
    private(set) var spaces: [BrowserSpaceRecord]
    /// The space a new window opens in.
    private(set) var lastActiveSpaceID: UUID?

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// True when no store existed yet: pins from an earlier version's
    /// window sessions are migrated into the first space.
    @ObservationIgnored private(set) var acceptsLegacyPins: Bool

    private struct File: Codable {
        var version = 1
        var spaces: [BrowserSpaceRecord]
        var lastActiveSpaceID: UUID?
    }

    static let iconChoices = ["house", "briefcase", "book", "sparkles", "leaf", "flame", "moon", "star",
                              "heart", "bolt", "globe", "graduationcap", "paintpalette", "gamecontroller",
                              "music.note", "camera", "cart", "airplane", "cup.and.saucer", "hammer"]

    static func fileURL(besideSession session: URL) -> URL {
        session.deletingLastPathComponent().appendingPathComponent(session.deletingPathExtension().lastPathComponent + "-spaces.json")
    }

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let file = try? JSONDecoder().decode(File.self, from: data), !file.spaces.isEmpty {
            spaces = file.spaces
            lastActiveSpaceID = file.lastActiveSpaceID
            acceptsLegacyPins = false
        } else {
            spaces = [BrowserSpaceRecord(name: L10n.string("Home"), icon: "house")]
            lastActiveSpaceID = nil
            acceptsLegacyPins = true
        }
    }

    var defaultSpaceID: UUID {
        if let lastActiveSpaceID, spaces.contains(where: { $0.id == lastActiveSpaceID }) { return lastActiveSpaceID }
        return spaces[0].id
    }

    func space(_ id: UUID) -> BrowserSpaceRecord? { spaces.first { $0.id == id } }

    func noteActive(_ id: UUID) {
        guard lastActiveSpaceID != id else { return }
        lastActiveSpaceID = id
        scheduleSave()
    }

    @discardableResult
    func addSpace(name: String? = nil, icon: String? = nil, origin: AnyObject?) -> UUID {
        let used = Set(spaces.map(\.icon))
        let record = BrowserSpaceRecord(name: name ?? L10n.format("Space %d", spaces.count + 1),
                                        icon: icon ?? Self.iconChoices.first { !used.contains($0) } ?? "circle")
        spaces.append(record)
        changed(origin: origin)
        return record.id
    }

    func updateSpace(_ id: UUID, name: String? = nil, icon: String? = nil) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { spaces[index].name = trimmed }
        }
        if let icon { spaces[index].icon = icon }
        changed(origin: nil)
    }

    func removeSpace(_ id: UUID) {
        guard spaces.count > 1 else { return }
        spaces.removeAll { $0.id == id }
        if lastActiveSpaceID == id { lastActiveSpaceID = spaces.first?.id }
        changed(origin: nil)
    }

    func moveSpace(_ id: UUID, by offset: Int) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(0, index + offset), spaces.count - 1)
        guard destination != index else { return }
        spaces.insert(spaces.remove(at: index), at: destination)
        changed(origin: nil)
    }

    func setPinned(_ nodes: [SidebarNodeRecord], in spaceID: UUID, origin: AnyObject?) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }), spaces[index].pinned != nodes else { return }
        spaces[index].pinned = nodes
        changed(origin: origin)
    }

    /// Titles change as pages load; they need saving but no other window must rebuild.
    func refreshPinnedTitles(_ titles: [UUID: String]) {
        var didChange = false
        for spaceIndex in spaces.indices {
            for nodeIndex in spaces[spaceIndex].pinned.indices {
                switch spaces[spaceIndex].pinned[nodeIndex] {
                case .tab(var tab):
                    if let title = titles[tab.id], !title.isEmpty, title != tab.title {
                        tab.title = title
                        spaces[spaceIndex].pinned[nodeIndex] = .tab(tab)
                        didChange = true
                    }
                case .group(var group):
                    var groupChanged = false
                    for tabIndex in group.tabs.indices {
                        if let title = titles[group.tabs[tabIndex].id], !title.isEmpty, title != group.tabs[tabIndex].title {
                            group.tabs[tabIndex].title = title
                            groupChanged = true
                        }
                    }
                    if groupChanged {
                        spaces[spaceIndex].pinned[nodeIndex] = .group(group)
                        didChange = true
                    }
                }
            }
        }
        if didChange { scheduleSave() }
    }

    func finishLegacyMigration() {
        guard acceptsLegacyPins else { return }
        acceptsLegacyPins = false
        scheduleSave()
    }

    private func changed(origin: AnyObject?) {
        scheduleSave()
        NotificationCenter.default.post(name: .nousSpacesDidChange, object: origin)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        saveTask?.cancel()
        saveTask = nil
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(File(spaces: spaces, lastActiveSpaceID: lastActiveSpaceID))
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("Nous Browser: Could not save spaces: %@", error.localizedDescription)
        }
    }
}
