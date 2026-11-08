import Foundation

/// A space → group → tab structure to build, as an agent describes it over MCP.
nonisolated struct BrowserLayoutPlan: Equatable, Sendable {
    struct Tab: Equatable, Sendable {
        var url: URL
        var title: String?
    }

    struct Group: Equatable, Sendable {
        var name: String
        var icon: String?
        var expanded: Bool?
        var tabs: [Tab]
    }

    enum Item: Equatable, Sendable {
        case tab(Tab)
        case group(Group)
    }

    struct Space: Equatable, Sendable {
        var name: String
        var icon: String?
        var pinned: [Item]
        var tabs: [Item]
    }

    var spaces: [Space]

    static let maximumSpaces = 20
    static let maximumTabs = 300

    var tabCount: Int {
        spaces.reduce(0) { total, space in
            total + (space.pinned + space.tabs).reduce(0) { count, item in
                switch item {
                case .tab: count + 1
                case .group(let group): count + group.tabs.count
                }
            }
        }
    }

    static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(b.trimmingCharacters(in: .whitespacesAndNewlines),
                     options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// The same page, ignoring the scheme's case, a "www." prefix, a trailing
    /// slash and the fragment.
    static func sameAddress(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        return normalized(a) == normalized(b)
    }

    private static func normalized(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        if var host = components.host?.lowercased() {
            if host.hasPrefix("www.") { host.removeFirst(4) }
            components.host = host
        }
        if components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string ?? url.absoluteString
    }
}

nonisolated struct BrowserLayoutPlanResult: Equatable, Sendable {
    struct Space: Equatable, Sendable { var id: UUID; var name: String; var created: Bool }
    struct Group: Equatable, Sendable { var id: UUID; var name: String; var spaceID: UUID }

    var spaces: [Space] = []
    var groups: [Group] = []
    var tabIDs: [UUID] = []
    var createdGroups = 0
    var createdTabs = 0
    var movedTabs = 0
    var keptTabs = 0
}
