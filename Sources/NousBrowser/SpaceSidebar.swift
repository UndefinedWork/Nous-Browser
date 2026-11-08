import AppKit
import SwiftUI

// The sidebar after Pico 427:2156 / 427:2242 / 438:1225 and Dia/Arc:
// pinned tiles, folders, ordinary tabs; one horizontally paged list per space
// (two-finger swipe to switch); back/forward/reload in one glass control.

enum SidebarMetrics {
    static let tileHeight: CGFloat = 32
    static let tileSpacing: CGFloat = 5
    static let folderHeight: CGFloat = 32
    /// Inner padding of an open folder's container.
    static let folderInset: CGFloat = 3
    /// Child tabs sit this far in from the folder header.
    static let folderIndent: CGFloat = 10
    static let coordinateSpace = SidebarTabDragGeometry.coordinateSpace
}

/// Measured frames, in the sidebar's coordinate space, of everything a drag can land on.
nonisolated enum SidebarFrameID: Hashable, Sendable {
    case tab(UUID)
    case tile(UUID)
    case group(UUID)
    /// A folder's header plus its visible tabs.
    case folderBody(UUID)
    case pinZone(UUID)
    case regularZone(UUID)
}

struct SidebarFramePreference: PreferenceKey {
    static let defaultValue: [SidebarFrameID: CGRect] = [:]
    static func reduce(value: inout [SidebarFrameID: CGRect], nextValue: () -> [SidebarFrameID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

extension View {
    fileprivate func sidebarFrame(_ id: SidebarFrameID) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: SidebarFramePreference.self,
                                       value: [id: proxy.frame(in: .named(SidebarMetrics.coordinateSpace))])
            }
        }
    }
}

/// A drag in progress inside one space's list.
struct SidebarDragState: Equatable {
    var item: SidebarItemRef
    var space: UUID
    var pointer: CGPoint
    var grab: CGSize
    var target: SidebarDropTarget
    var size: CGSize
    var isOutside = false
    var hoveredGroup: UUID?
}

// MARK: - Sidebar

struct BrowserSidebar: View {
    let controller: BrowserController
    let tooltip: SidebarTabTooltipState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var frames: [SidebarFrameID: CGRect] = [:]
    @State private var drag: SidebarDragState?
    @State private var visibleSpace: UUID?
    @State private var renamingGroup: UUID?
    @State private var spaceBanner: UUID?
    @State private var editingSpace: UUID?
    @State private var dragWindow = SidebarDragWindowReference()
    @State private var springLoad: Task<Void, Never>?
    private var model: BrowserModel { controller.model }

    var body: some View {
        GeometryReader { geometry in
            let compact = model.isSidebarCompact
            ZStack(alignment: .topLeading) {
                spacePager(size: geometry.size)

                VStack(spacing: 0) {
                    SidebarEdgeGlass(edge: .top,
                                     buttonCenters: compact ? [30] : [30, geometry.size.width - 30],
                                     height: compact ? 132 : 88,
                                     controlCenterFromEdge: compact ? 52 : 30)
                    Spacer(minLength: 0)
                    SidebarEdgeGlass(edge: .bottom,
                                     buttonCenters: compact ? [30] : [52, geometry.size.width / 2, geometry.size.width - 28],
                                     height: compact ? 196 : 88,
                                     controlCenterFromEdge: compact ? 80 : 28)
                }
                .frame(width: geometry.size.width + BrowserDesign.pageRadius * 2)
                .frame(width: geometry.size.width, alignment: .leading)
                .allowsHitTesting(false)

                if let drag, !drag.isOutside { floatingItem(drag, width: geometry.size.width) }

                SidebarControls(controller: controller, size: geometry.size,
                                editingSpace: $editingSpace, spaceBanner: spaceBanner)

                WindowDragArea()
                    .frame(height: BrowserDesign.inset)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .coordinateSpace(name: SidebarMetrics.coordinateSpace)
            .onPreferenceChange(SidebarFramePreference.self) { frames = $0 }
            .background {
                SidebarDragCancellationMonitor(isEnabled: drag != nil, canCancel: drag != nil,
                                               onCancel: { cancelDrag() }, windowReference: dragWindow,
                                               onPointerRelease: { _ in }, onPointerPress: {})
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                SidebarTooltipDismissalMonitor(isEnabled: tooltip.isTracking, dismiss: tooltip.dismiss)
                    .frame(width: 0, height: 0)
            }
            .onChange(of: model.isSidebarCompact) { _, _ in cancelDrag(); tooltip.dismiss() }
            .onChange(of: model.activeSpaceID) { _, id in
                tooltip.dismiss()
                if visibleSpace != id { withAnimation(reduceMotion ? nil : BrowserMotion.spring) { visibleSpace = id } }
                showBanner(id)
            }
            .onAppear { visibleSpace = model.activeSpaceID }
        }
        .contextMenu {
            Button(L10n.string("New Tab"), systemImage: "plus", action: controller.newTab)
            Button(L10n.string("New Group"), systemImage: "folder.badge.plus") { newFolder() }
            Button(L10n.string("New Space"), systemImage: "square.stack.3d.up.badge.automatic") {
                withAnimation(BrowserMotion.spring) { model.newSpace() }
                editingSpace = model.activeSpaceID
            }
            Divider()
            Button(L10n.string(model.isSidebarCompact ? "Expand Sidebar" : "Collapse Sidebar"), systemImage: "sidebar.left") {
                model.toggleSidebar()
            }
            Button(L10n.string("Hide Sidebar"), systemImage: "rectangle") { model.toggleSidebarHidden() }
            Divider()
            Button(L10n.string("New Window"), systemImage: "macwindow.badge.plus", action: controller.newWindow)
            Button(L10n.string("Close Window"), systemImage: "xmark.rectangle", action: controller.closeWindow)
        }
    }

    private func newFolder() {
        withAnimation(reduceMotion ? nil : BrowserMotion.spring) {
            renamingGroup = model.newGroup()
        }
    }

    private func showBanner(_ id: UUID) {
        withAnimation(BrowserMotion.spring) { spaceBanner = id }
        Task {
            try? await Task.sleep(for: .seconds(1.3))
            if spaceBanner == id { withAnimation(BrowserMotion.spring) { spaceBanner = nil } }
        }
    }

    // MARK: Paging

    private func spacePager(size: CGSize) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(model.spaces) { space in
                    SpaceColumn(controller: controller, space: space.id, layout: displayedLayout(for: space.id),
                                drag: drag, renamingGroup: $renamingGroup, tooltip: tooltip, frames: frames,
                                actions: dragActions(size: size))
                        .frame(width: size.width, height: size.height)
                        .id(space.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $visibleSpace)
        .scrollIndicators(.hidden)
        .scrollDisabled(drag != nil || model.spaces.count < 2)
        .onChange(of: visibleSpace) { _, id in
            guard let id, id != model.activeSpaceID else { return }
            tooltip.dismiss()
            model.switchSpace(to: id)
        }
    }

    /// While dragging, the list shows where the item will land.
    private func displayedLayout(for space: UUID) -> SpaceLayout {
        let layout = model.layout(for: space)
        guard let drag, drag.space == space, !drag.isOutside else { return layout }
        // Dropping into a closed folder keeps the list still; the folder lights up instead.
        if let id = drag.target.groupID, layout.group(id)?.isExpanded == false { return layout }
        return layout.moving(drag.item, to: drag.target)
    }

    @ViewBuilder
    private func floatingItem(_ drag: SidebarDragState, width: CGFloat) -> some View {
        let center = CGPoint(x: drag.pointer.x - drag.grab.width + drag.size.width / 2,
                             y: drag.pointer.y - drag.grab.height + drag.size.height / 2)
        Group {
            switch drag.item {
            case .tab(let id):
                if let tab = model.tab(id) {
                    SidebarFloatingTab(tab: tab, isSettling: false, isCompact: model.isSidebarCompact || drag.size.width < 60)
                }
            case .group(let id):
                if let group = model.layout(for: drag.space).group(id) {
                    FolderLabel(group: group, compact: model.isSidebarCompact)
                        .padding(.horizontal, 12)
                        .frame(height: SidebarMetrics.folderHeight)
                        .background((colorScheme == .dark ? Color(white: 0.22) : Color.white).opacity(0.96), in: Capsule())
                        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
                }
            }
        }
        .frame(width: max(32, drag.size.width), height: max(30, drag.size.height))
        .position(center)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    // MARK: Dragging

    private func dragActions(size: CGSize) -> SidebarDragActions {
        SidebarDragActions(changed: { item, space, value in dragChanged(item, space: space, value: value, size: size) },
                           ended: { item, value in dragEnded(item, value: value, size: size) })
    }

    private func dragChanged(_ item: SidebarItemRef, space: UUID, value: DragGesture.Value, size: CGSize) {
        tooltip.dismiss()
        if drag == nil {
            let frame: CGRect? = switch item {
            case .tab(let id): frames[.tile(id)] ?? frames[.tab(id)]
            case .group(let id): frames[.group(id)]
            }
            guard let frame, let start = currentTarget(of: item, in: space) else { return }
            drag = SidebarDragState(item: item, space: space, pointer: value.location,
                                    grab: CGSize(width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY),
                                    target: start, size: frame.size)
            NSCursor.closedHand.set()
        }
        guard var state = drag else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        state.pointer = value.location
        let outside = value.location.x > size.width + 40 || value.location.x < -40 || value.location.y < -30 || value.location.y > size.height + 30
        if outside != state.isOutside, case .tab(let id) = state.item, model.tab(id)?.isPinned == false {
            state.isOutside = outside
            if outside, let tab = model.tab(id), let point = dragWindow.screenPoint(forSidebarPoint: value.location) {
                controller.tabDragCoordinator?.begin(tab: tab, source: controller, at: point,
                                                     rowSize: CGSize(width: max(state.size.width, 180), height: BrowserDesign.rowHeight),
                                                     grabOffset: CGPoint(x: state.grab.width, y: state.grab.height))
            } else if !outside {
                controller.tabDragCoordinator?.cancel()
            }
        }
        if state.isOutside, let point = dragWindow.screenPoint(forSidebarPoint: value.location) {
            controller.tabDragCoordinator?.update(at: point)
            withTransaction(transaction) { drag = state }
            return
        }
        let (target, hovered) = proposedTarget(for: state, size: size)
        if hovered != state.hoveredGroup { folderHoverChanged(hovered, space: state.space) }
        state.hoveredGroup = hovered
        if let target, target != state.target {
            withTransaction(transaction) { drag = state }
            withAnimation(reduceMotion ? nil : BrowserMotion.spring) { drag?.target = target }
        } else {
            withTransaction(transaction) { drag = state }
        }
    }

    /// Finder-style spring loading: resting on a closed folder opens it.
    private func folderHoverChanged(_ group: UUID?, space: UUID) {
        springLoad?.cancel()
        springLoad = nil
        guard let group else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        guard model.layout(for: space).group(group)?.isExpanded == false else { return }
        springLoad = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, drag?.hoveredGroup == group else { return }
            withAnimation(reduceMotion ? nil : BrowserMotion.spring) { model.updateGroup(group, isExpanded: true) }
        }
    }

    private func dragEnded(_ item: SidebarItemRef, value: DragGesture.Value, size: CGSize) {
        springLoad?.cancel()
        springLoad = nil
        NSCursor.arrow.set()
        guard let state = drag, state.item == item else { drag = nil; return }
        if state.isOutside, case .tab(let id) = item, let point = dragWindow.screenPoint(forSidebarPoint: value.location) {
            controller.tabDragCoordinator?.cancel()
            drag = nil
            dropOutside(id, at: point)
            return
        }
        withAnimation(reduceMotion ? nil : BrowserMotion.spring) {
            model.move(item, to: state.target, in: state.space)
            drag = nil
        }
    }

    private func cancelDrag() {
        springLoad?.cancel()
        springLoad = nil
        guard drag != nil else { return }
        controller.tabDragCoordinator?.cancel()
        NSCursor.arrow.set()
        withAnimation(reduceMotion ? nil : BrowserMotion.spring) { drag = nil }
    }

    /// Another browser window under the pointer adopts the tab; elsewhere it becomes a new window.
    private func dropOutside(_ id: UUID, at point: NSPoint) {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        if let window = NSApp.window(withWindowNumber: number) as? BrowserWindow, let target = window.browserController,
           target !== controller {
            _ = controller.moveTab(id, to: target, at: target.model.activeLayout.regular.count)
        } else if let window = dragWindow.window, !window.frame.insetBy(dx: -8, dy: -8).contains(point) {
            _ = controller.moveTabToNewWindow(id, at: point)
        }
    }

    private func currentTarget(of item: SidebarItemRef, in space: UUID) -> SidebarDropTarget? {
        let layout = model.layout(for: space)
        switch item {
        case .tab(let id):
            guard let location = layout.location(of: id) else { return nil }
            let siblings = location.groupID.flatMap { layout.group($0)?.tabIDs } ?? layout.nodes(location.section).map(\.id)
            return SidebarDropTarget(section: location.section, groupID: location.groupID, index: siblings.firstIndex(of: id) ?? 0)
        case .group(let id):
            guard let section = layout.section(ofGroup: id),
                  let index = layout.nodes(section).firstIndex(where: { $0.id == id }) else { return nil }
            return SidebarDropTarget(section: section, groupID: nil, index: index)
        }
    }

    /// Where the pointer would drop the item, from the rows as currently drawn.
    private func proposedTarget(for state: SidebarDragState, size: CGSize) -> (SidebarDropTarget?, UUID?) {
        let layout = model.layout(for: state.space).moving(state.item, to: state.target)
        let draggedID = state.item.id
        let pointer = state.pointer
        let pinZone = frames[.pinZone(state.space)]
        let regularTop = frames[.regularZone(state.space)]?.minY ?? (pinZone?.maxY ?? 0) + 8
        let inPinned = pointer.y < regularTop - 4

        // The base layout has the item removed (appended last); indices are counted without it.
        func withoutItem(_ nodes: [SidebarNode]) -> [SidebarNode] {
            nodes.filter { $0.id != draggedID }.map { node in
                guard case .group(var group) = node else { return node }
                group.tabIDs.removeAll { $0 == draggedID }
                return .group(group)
            }
        }
        if case .group = state.item {
            let section: SidebarSection = inPinned ? .pinned : .regular
            let nodes = withoutItem(layout.nodes(section))
            var index = nodes.count
            for (position, node) in nodes.enumerated() {
                let frame: CGRect? = node.group != nil ? frames[.group(node.id)] : frames[section == .pinned ? .tile(node.id) : .tab(node.id)]
                if let frame, pointer.y < frame.midY, node.group != nil || section == .regular { index = position; break }
            }
            if section == .pinned { index = max(index, nodes.filter { $0.group == nil }.count) }
            return (SidebarDropTarget(section: section, groupID: nil, index: index), nil)
        }

        if inPinned {
            let nodes = withoutItem(layout.pinned)
            // Tiles in reading order.
            let tiles = nodes.compactMap { node -> (UUID, CGRect)? in
                guard node.group == nil, let frame = frames[.tile(node.id)] else { return nil }
                return (node.id, frame)
            }
            let tilesBottom = tiles.map(\.1.maxY).max() ?? frames[.pinZone(state.space)]?.minY ?? 0
            if pointer.y > tilesBottom + 4, let found = rowTarget(section: .pinned, nodes: nodes, pointer: pointer) {
                return found
            }
            var index = tiles.count
            for (position, tile) in tiles.enumerated() {
                let frame = tile.1
                if pointer.y < frame.minY - 2 || (pointer.y <= frame.maxY + 2 && pointer.x < frame.midX) { index = position; break }
            }
            return (SidebarDropTarget(section: .pinned, groupID: nil, index: index), nil)
        }
        return rowTarget(section: .regular, nodes: withoutItem(layout.regular), pointer: pointer)
            ?? (SidebarDropTarget(section: .regular, groupID: nil, index: layout.regular.count), nil)
    }

    /// Rows top to bottom. A folder owns everything from just below the top of
    /// its header to the bottom of its container, so the whole folder (not a
    /// thin strip of the header) accepts a tab; its top edge inserts above it.
    private func rowTarget(section: SidebarSection, nodes: [SidebarNode], pointer: CGPoint) -> (SidebarDropTarget, UUID?)? {
        for (index, node) in nodes.enumerated() {
            switch node {
            case .tab(let id):
                if section == .pinned { continue }
                if let frame = frames[.tab(id)], pointer.y < frame.midY {
                    return (SidebarDropTarget(section: section, groupID: nil, index: index), nil)
                }
            case .group(let group):
                guard let header = frames[.group(group.id)] else { continue }
                let body = frames[.folderBody(group.id)] ?? header
                if pointer.y < header.minY + header.height * 0.28 {
                    return (SidebarDropTarget(section: section, groupID: nil, index: index), nil)
                }
                guard pointer.y <= body.maxY else { continue }
                var child = group.tabIDs.count
                if group.isExpanded {
                    for (position, id) in group.tabIDs.enumerated() {
                        if let frame = frames[.tab(id)], pointer.y < frame.midY { child = position; break }
                    }
                }
                return (SidebarDropTarget(section: section, groupID: group.id, index: child), group.id)
            }
        }
        return section == .regular ? (SidebarDropTarget(section: section, groupID: nil, index: nodes.count), nil) : nil
    }
}

struct SidebarDragActions {
    let changed: (SidebarItemRef, UUID, DragGesture.Value) -> Void
    let ended: (SidebarItemRef, DragGesture.Value) -> Void
}

private struct SidebarItemDrag: ViewModifier {
    let item: SidebarItemRef
    let space: UUID
    let actions: SidebarDragActions

    func body(content: Content) -> some View {
        content.highPriorityGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(SidebarMetrics.coordinateSpace))
                .onChanged { actions.changed(item, space, $0) }
                .onEnded { actions.ended(item, $0) }
        )
    }
}

// MARK: - One space

private struct SpaceColumn: View {
    let controller: BrowserController
    let space: UUID
    let layout: SpaceLayout
    let drag: SidebarDragState?
    @Binding var renamingGroup: UUID?
    let tooltip: SidebarTabTooltipState
    let frames: [SidebarFrameID: CGRect]
    let actions: SidebarDragActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var model: BrowserModel { controller.model }
    private var compact: Bool { model.isSidebarCompact }
    private var isDraggingTab: Bool { if case .tab = drag?.item, drag?.space == space { true } else { false } }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                pinnedArea
                    .sidebarFrame(.pinZone(space))
                regularArea
                    .sidebarFrame(.regularZone(space))
            }
            .padding(.horizontal, compact ? 12 : BrowserDesign.inset)
            .padding(.top, SidebarTabDragGeometry.topInset(isCompact: compact))
            .padding(.bottom, compact ? 196 : SidebarTabDragGeometry.bottomInset(isCompact: false) + 12)
            .frame(maxWidth: .infinity, minHeight: 0, alignment: .top)
            .windowDragBackground()
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(drag != nil)
        .animation(reduceMotion ? nil : BrowserMotion.spring, value: layout)
    }

    // MARK: Pinned

    @ViewBuilder private var pinnedArea: some View {
        let tiles = layout.pinned.filter { $0.group == nil }.map(\.id)
        let folders = layout.pinned.compactMap(\.group)
        VStack(spacing: 1) {
            if !tiles.isEmpty {
                PinnedGrid(controller: controller, space: space, ids: tiles, compact: compact,
                           draggedID: drag?.space == space ? drag?.item.id : nil, actions: actions)
                    .padding(.bottom, folders.isEmpty ? 0 : 6)
            } else if isDraggingTab, !compact {
                Label(L10n.string("Drop to Pin"), systemImage: "pin")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).frame(height: SidebarMetrics.tileHeight)
                    .background(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.secondary.opacity(0.5)))
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            ForEach(folders) { group in folder(group, section: .pinned) }
            if !layout.pinned.isEmpty, !layout.regular.isEmpty || compact {
                if compact {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(width: 20, height: 1).padding(.vertical, 8)
                } else {
                    Color.clear.frame(height: 10)
                }
            }
        }
    }

    // MARK: Ordinary

    private var regularArea: some View {
        VStack(spacing: SidebarTabDragGeometry.rowSpacing) {
            ForEach(layout.regular) { node in
                switch node {
                case .tab(let id): tabRow(id, in: nil)
                case .group(let group): folder(group, section: .regular)
                }
            }
            // Room to drop below the last row.
            Color.clear.frame(height: 40).contentShape(Rectangle()).windowDragBackground()
        }
    }

    /// A folder reads as one object: a soft container holds the header and its
    /// indented tabs. Closed, it keeps showing the tab you are on (as Arc does).
    @ViewBuilder
    private func folder(_ group: TabGroup, section: SidebarSection) -> some View {
        let dragged = drag?.item == .group(group.id) && drag?.space == space
        let isTarget = drag?.hoveredGroup == group.id && drag?.space == space
        let visible = group.isExpanded ? group.tabIDs : group.tabIDs.filter { $0 == model.selectedTabID }
        let contained = !visible.isEmpty || group.isExpanded && (group.tabIDs.isEmpty || isDraggingTab)
        VStack(spacing: SidebarTabDragGeometry.rowSpacing) {
            FolderHeader(controller: controller, group: group, section: section, compact: compact,
                         isRenaming: Binding(get: { renamingGroup == group.id }, set: { if !$0 { renamingGroup = nil } }),
                         isDropTarget: isTarget,
                         startRename: { renamingGroup = group.id })
                .sidebarFrame(.group(group.id))
                .modifier(SidebarItemDrag(item: .group(group.id), space: space, actions: actions))
            ForEach(visible, id: \.self) { id in
                tabRow(id, in: group)
                    .padding(.leading, compact ? 0 : SidebarMetrics.folderIndent)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -8)),
                                            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))))
            }
            if group.isExpanded, group.tabIDs.isEmpty {
                Text(L10n.string(isTarget ? "Drop Here" : "Empty"))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).frame(height: 26)
                    .opacity(compact ? 0 : 1)
                    .transition(.opacity)
            }
        }
        .padding(contained || isTarget ? SidebarMetrics.folderInset : 0)
        .background {
            let shape = RoundedRectangle(cornerRadius: (compact ? 18 : BrowserDesign.rowHeight / 2) + SidebarMetrics.folderInset,
                                         style: .continuous)
            shape.fill(isTarget ? Color.accentColor.opacity(0.12)
                       : Color.primary.opacity(contained ? (colorScheme == .dark ? 0.06 : 0.045) : 0))
                .overlay { shape.strokeBorder(Color.accentColor.opacity(isTarget ? 0.45 : 0), lineWidth: 1) }
        }
        .padding(.horizontal, contained || isTarget ? -SidebarMetrics.folderInset : 0)
        .sidebarFrame(.folderBody(group.id))
        .scaleEffect(isTarget && !group.isExpanded && !reduceMotion ? 1.02 : 1)
        .animation(reduceMotion ? nil : BrowserMotion.interaction, value: isTarget)
        .animation(reduceMotion ? nil : BrowserMotion.spring, value: contained)
        .padding(.vertical, contained ? 2 : 0)
        .opacity(dragged ? 0 : 1)
    }

    @ViewBuilder
    private func tabRow(_ id: UUID, in group: TabGroup?) -> some View {
        if let tab = model.tab(id) {
            let dragged = drag?.item == .tab(id) && drag?.space == space
            BrowserTabRow(tab: tab, selected: model.selectedTabID == id, isCompact: compact,
                          select: { withAnimation(reduceMotion ? nil : BrowserMotion.tabSwitch) { model.selectTab(id) } },
                          close: { withAnimation(reduceMotion ? nil : BrowserMotion.spring) { model.closeTab(id) } },
                          copy: { controller.copyURL(tab, showsToast: false) },
                          newTab: controller.newTab,
                          duplicate: { withAnimation(reduceMotion ? nil : BrowserMotion.spring) { model.duplicateTab(id) } },
                          togglePin: { withAnimation(reduceMotion ? nil : BrowserMotion.spring) { model.togglePin(id) } },
                          editAddress: controller.showAddress,
                          menu: AnyView(TabOrganizeMenu(controller: controller, tabID: id, groupID: group?.id)),
                          moveUp: { withAnimation(BrowserMotion.spring) { model.moveTab(id, by: -1) } },
                          moveDown: { withAnimation(BrowserMotion.spring) { model.moveTab(id, by: 1) } },
                          canMoveUp: model.canMoveTab(id, by: -1),
                          canMoveDown: model.canMoveTab(id, by: 1),
                          hoverChanged: { hovering in
                              if hovering, compact, drag == nil, let frame = frames[.tab(id)] {
                                  tooltip.hover(tabID: id, title: tab.displayTitle, centerY: frame.midY)
                              } else { tooltip.leave(tabID: id) }
                          })
                .sidebarFrame(.tab(id))
                .modifier(SidebarItemDrag(item: .tab(id), space: space, actions: actions))
                .opacity(dragged ? 0 : 1)
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                                        removal: .scale(scale: 0.92).combined(with: .opacity)))
        }
    }
}

// MARK: - Pinned tiles

private struct PinnedGrid: View {
    let controller: BrowserController
    let space: UUID
    let ids: [UUID]
    let compact: Bool
    let draggedID: UUID?
    let actions: SidebarDragActions

    var body: some View {
        TileGridLayout(compact: compact) {
            ForEach(ids, id: \.self) { id in tile(id) }
        }
    }

    @ViewBuilder
    private func tile(_ id: UUID) -> some View {
        if let tab = controller.model.tab(id) {
            PinnedTile(controller: controller, tab: tab)
                .sidebarFrame(.tile(id))
                .modifier(SidebarItemDrag(item: .tab(id), space: space, actions: actions))
                .opacity(draggedID == id ? 0 : 1)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }
}

/// Up to four pins fill the row as wide tiles (Pico 438:1225); more become a
/// grid of circles (Pico 427:2156); the icon rail stacks them (Pico 427:2242).
struct TileGridLayout: Layout {
    var compact: Bool

    private func columns(count: Int, width: CGFloat) -> Int {
        if compact { return 1 }
        let spacing = SidebarMetrics.tileSpacing
        let fitting = max(1, Int((width + spacing) / (SidebarMetrics.tileHeight + spacing)))
        return max(1, count <= 4 ? count : min(fitting, 6))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 219
        let columns = columns(count: subviews.count, width: width)
        let rows = (subviews.count + columns - 1) / columns
        return CGSize(width: width, height: CGFloat(rows) * SidebarMetrics.tileHeight + CGFloat(max(0, rows - 1)) * SidebarMetrics.tileSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let spacing = SidebarMetrics.tileSpacing
        let columns = columns(count: subviews.count, width: bounds.width)
        let cell = (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        for (index, subview) in subviews.enumerated() {
            let row = index / columns, column = index % columns
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(column) * (cell + spacing),
                                      y: bounds.minY + CGFloat(row) * (SidebarMetrics.tileHeight + spacing)),
                          proposal: ProposedViewSize(width: cell, height: SidebarMetrics.tileHeight))
        }
    }
}

private struct PinnedTile: View {
    let controller: BrowserController
    let tab: BrowserTab
    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var selected: Bool { controller.model.selectedTabID == tab.id }

    var body: some View {
        Button { withAnimation(reduceMotion ? nil : BrowserMotion.tabSwitch) { controller.model.selectTab(tab.id) } } label: {
            SidebarTabFavicon(tab: tab)
                .scaleEffect(1.1)
                .opacity(tab.hasWebContent && !tab.isLoading || selected ? 1 : 0.85)
                .frame(maxWidth: .infinity)
                .frame(height: SidebarMetrics.tileHeight)
                .background(background, in: Capsule())
                .overlay {
                    Capsule().strokeBorder((colorScheme == .dark ? Color.white : Color.black).opacity(selected ? 0.1 : 0.04), lineWidth: 0.5)
                }
                .contentShape(Capsule())
                .scaleEffect(hovered && !reduceMotion ? 1.04 : 1)
        }
        .buttonStyle(PressSpringStyle())
        .onHover { value in withAnimation(reduceMotion ? nil : BrowserMotion.interaction) { hovered = value } }
        .help(tab.displayTitle)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityValue(L10n.string("Pinned"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button(L10n.string("Copy Link"), systemImage: "link") { controller.copyURL(tab) }.disabled(tab.url == nil)
            Button(L10n.string("Duplicate Tab"), systemImage: "plus.square.on.square") { controller.model.duplicateTab(tab.id) }
            Button(L10n.string("Unpin Tab"), systemImage: "pin.slash") {
                withAnimation(BrowserMotion.spring) { controller.model.togglePin(tab.id) }
            }
            TabOrganizeMenu(controller: controller, tabID: tab.id, groupID: nil)
            Divider()
            Button(L10n.string("Close Tab"), systemImage: "xmark") { controller.model.closeTab(tab.id) }
                .disabled(!tab.hasWebContent)
        }
    }

    private var background: Color {
        if colorScheme == .dark { return Color.white.opacity(selected ? 0.16 : hovered ? 0.10 : 0.06) }
        return Color.white.opacity(selected ? 1 : hovered ? 0.75 : 0.5)
    }
}

struct PressSpringStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(BrowserMotion.interaction, value: configuration.isPressed)
    }
}

// MARK: - Folders

private struct FolderLabel: View {
    let group: TabGroup
    let compact: Bool

    var body: some View {
        HStack(spacing: 7) {
            FolderIcon(icon: group.icon, isExpanded: group.isExpanded)
                .symbolEffect(.bounce, value: group.tabIDs.count)
            if !compact {
                Text(group.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .foregroundStyle(.primary.opacity(0.8))
                Spacer(minLength: 4)
                if !group.isExpanded, !group.tabIDs.isEmpty {
                    Text("\(group.tabIDs.count)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .contentTransition(.numericText())
                        .transition(.opacity)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(group.isExpanded ? 90 : 0))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
    }
}

struct FolderIcon: View {
    let icon: String
    var isExpanded = true

    var body: some View {
        Group {
            if icon.unicodeScalars.first?.properties.isEmojiPresentation == true || icon.count == 1 && !icon.allSatisfy(\.isLetter) {
                Text(icon).font(.system(size: 13))
            } else if icon == TabGroup.defaultIcon {
                Image(systemName: isExpanded ? "folder" : "folder.fill").font(.system(size: 12))
                    .contentTransition(.symbolEffect(.replace))
            } else {
                Image(systemName: icon).font(.system(size: 12))
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// One button for the whole row (reliable hit area, also in the icon rail):
/// click toggles, double-click renames, drag moves, right-click edits.
private struct FolderHeader: View {
    let controller: BrowserController
    let group: TabGroup
    let section: SidebarSection
    let compact: Bool
    @Binding var isRenaming: Bool
    let isDropTarget: Bool
    let startRename: () -> Void
    @State private var draftName = ""
    @State private var hovered = false
    @State private var choosingIcon = false
    @State private var lastToggle: (date: Date, wasExpanded: Bool)?
    @FocusState private var nameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var model: BrowserModel { controller.model }

    var body: some View {
        Group {
            if isRenaming && !compact {
                HStack(spacing: 7) {
                    FolderIcon(icon: group.icon, isExpanded: group.isExpanded)
                    TextField("", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .focused($nameFocused)
                        .onSubmit(commit)
                        .onExitCommand { isRenaming = false }
                        .onAppear { draftName = group.name; nameFocused = true }
                        .onChange(of: nameFocused) { _, focused in if !focused { commit() } }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: SidebarMetrics.folderHeight)
                .background(Color.primary.opacity(0.06), in: Capsule())
            } else {
                Button(action: toggle) {
                    FolderLabel(group: group, compact: compact)
                        .padding(.horizontal, compact ? 0 : 12)
                        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
                        .frame(height: SidebarMetrics.folderHeight)
                        .background(Color.primary.opacity(hovered && !isDropTarget ? 0.05 : 0), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(FolderPressStyle())
                .simultaneousGesture(TapGesture(count: 2).onEnded { rename() })
            }
        }
        .onHover { value in withAnimation(reduceMotion ? nil : BrowserMotion.interaction) { hovered = value } }
        .help(compact ? group.name : "")
        .popover(isPresented: $choosingIcon, arrowEdge: .trailing) {
            IconPicker(selection: group.icon) { icon in model.updateGroup(group.id, icon: icon); choosingIcon = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(group.name)
        .accessibilityValue(L10n.string(group.isExpanded ? "Expanded" : "Collapsed"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
        .accessibilityAction(named: L10n.string("Rename Group"), startRename)
        .contextMenu {
            Button(L10n.string("Rename Group"), systemImage: "pencil", action: startRename)
            Button(L10n.string("Change Icon…"), systemImage: "face.smiling") { choosingIcon = true }
            Button(L10n.string(section == .pinned ? "Unpin Folder" : "Pin Folder"), systemImage: section == .pinned ? "pin.slash" : "pin") {
                withAnimation(BrowserMotion.spring) { model.toggleGroupPinned(group.id) }
            }
            Button(L10n.string("New Tab in Group"), systemImage: "plus") {
                model.newTab()
                if let id = model.selectedTabID {
                    withAnimation(BrowserMotion.spring) {
                        model.updateGroup(group.id, isExpanded: true)
                        model.move(.tab(id), to: SidebarDropTarget(section: section, groupID: group.id, index: group.tabIDs.count))
                    }
                }
                controller.showAddress()
            }
            Divider()
            Button(L10n.string("Ungroup"), systemImage: "folder.badge.minus") {
                withAnimation(BrowserMotion.spring) { model.ungroup(group.id) }
            }
            Button(L10n.string("Close Group"), systemImage: "xmark", role: .destructive) {
                withAnimation(BrowserMotion.spring) { model.closeGroup(group.id) }
            }
        }
    }

    private func toggle() {
        lastToggle = (Date(), group.isExpanded)
        withAnimation(reduceMotion ? nil : BrowserMotion.spring) { model.updateGroup(group.id, isExpanded: !group.isExpanded) }
    }

    /// The double-click's first click already toggled; put it back, then rename.
    private func rename() {
        guard !compact else { return }
        if let last = lastToggle, Date().timeIntervalSince(last.date) < NSEvent.doubleClickInterval + 0.1 {
            withAnimation(reduceMotion ? nil : BrowserMotion.spring) { model.updateGroup(group.id, isExpanded: last.wasExpanded) }
        }
        lastToggle = nil
        startRename()
    }

    private func commit() {
        guard isRenaming else { return }
        model.updateGroup(group.id, name: draftName)
        isRenaming = false
    }
}

private struct FolderPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(BrowserMotion.interaction, value: configuration.isPressed)
    }
}

struct IconPicker: View {
    let selection: String
    let choose: (String) -> Void
    @State private var emoji = ""
    static let symbols = ["folder", "star", "heart", "bookmark", "briefcase", "book", "cart", "gamecontroller",
                          "music.note", "sparkles", "flame", "leaf", "bolt", "hammer", "paintbrush", "camera",
                          "globe", "house", "graduationcap", "airplane", "cup.and.saucer", "lightbulb", "tray", "newspaper"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 6), spacing: 6) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    Button { choose(symbol) } label: {
                        Image(systemName: symbol).font(.system(size: 13)).frame(width: 28, height: 28)
                            .background(Color.primary.opacity(selection == symbol ? 0.14 : 0.04), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                TextField(L10n.string("Emoji"), text: $emoji)
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                    .onSubmit { if let first = emoji.first { choose(String(first)) } }
                Button(L10n.string("Use")) { if let first = emoji.first { choose(String(first)) } }
                    .disabled(emoji.isEmpty)
            }
        }
        .padding(14)
    }
}

/// Folder and space commands for a tab's context menu.
struct TabOrganizeMenu: View {
    let controller: BrowserController
    let tabID: UUID
    let groupID: UUID?
    private var model: BrowserModel { controller.model }

    var body: some View {
        let layout = model.layout(for: model.tab(tabID)?.spaceID ?? model.activeSpaceID)
        Menu(L10n.string("Add to Group"), systemImage: "folder") {
            Button(L10n.string("New Group"), systemImage: "folder.badge.plus") {
                withAnimation(BrowserMotion.spring) { _ = model.newGroup(containing: [tabID]) }
            }
            let others = layout.groups.filter { $0.id != groupID }
            if !others.isEmpty { Divider() }
            ForEach(others) { group in
                Button(group.name) {
                    guard let section = layout.section(ofGroup: group.id) else { return }
                    withAnimation(BrowserMotion.spring) {
                        model.move(.tab(tabID), to: SidebarDropTarget(section: section, groupID: group.id, index: group.tabIDs.count))
                    }
                }
            }
        }
        if let groupID, let section = layout.section(ofGroup: groupID),
           let index = layout.nodes(section).firstIndex(where: { $0.id == groupID }) {
            Button(L10n.string("Remove from Group"), systemImage: "folder.badge.minus") {
                withAnimation(BrowserMotion.spring) {
                    model.move(.tab(tabID), to: SidebarDropTarget(section: section, groupID: nil, index: index + 1))
                }
            }
        }
        if let tab = model.tab(tabID), tab.hasWebContent, tab.url != nil {
            let marked = LibraryStore.shared.isBookmarked(tab.url)
            Button(L10n.string(marked ? "Remove Bookmark" : "Add Bookmark"), systemImage: marked ? "star.slash" : "star") {
                controller.toggleBookmark(tab)
            }
        }
        if model.spaces.count > 1 {
            Menu(L10n.string("Move to Space"), systemImage: "square.stack.3d.up") {
                ForEach(model.spaces.filter { $0.id != model.tab(tabID)?.spaceID }) { space in
                    Button(space.name, systemImage: space.icon) {
                        withAnimation(BrowserMotion.spring) { model.moveTab(tabID, toSpace: space.id) }
                    }
                }
            }
        }
    }
}

// MARK: - Controls

private struct SidebarControls: View {
    let controller: BrowserController
    let size: CGSize
    @Binding var editingSpace: UUID?
    let spaceBanner: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var model: BrowserModel { controller.model }

    var body: some View {
        let compact = model.isSidebarCompact
        let topLabel = L10n.string(compact ? "Expand Sidebar" : "Collapse Sidebar")
        ZStack(alignment: .topLeading) {
            if !compact {
                WindowDragArea()
                    .frame(width: max(0, size.width - 120), height: BrowserDesign.buttonSize)
                    .position(x: size.width / 2, y: 30)
            }
            GlassSymbolButton("sidebar.left", label: topLabel, help: topLabel + "  ⌘/") { model.toggleSidebar() }
                .position(x: 30, y: 30)
            GlassSymbolButton("plus", label: L10n.string("New Tab"), help: L10n.string("New Tab") + "  ⌘T", action: controller.newTab)
                .position(x: compact ? 30 : size.width - 30, y: compact ? 74 : 30)

            NavigationCluster(controller: controller, vertical: compact)
                .position(x: compact ? 30 : BrowserDesign.inset + 42, y: compact ? size.height - 60 : size.height - 28)

            LibraryButton(controller: controller)
                .position(x: compact ? 30 : size.width - 28, y: compact ? size.height - 134 : size.height - 28)

            if !compact, model.spaces.count > 1 || editingSpace != nil {
                SpaceDots(controller: controller, editingSpace: $editingSpace)
                    .position(x: (BrowserDesign.inset + 84 + size.width - 46) / 2, y: size.height - 28)
                    .transition(.opacity)
            }
            if let id = spaceBanner, let space = model.spaces.first(where: { $0.id == id }), model.spaces.count > 1 {
                SpaceBanner(space: space, index: model.spaces.firstIndex(where: { $0.id == id }) ?? 0,
                            count: model.spaces.count, compact: compact, maxWidth: size.width - 24)
                    .position(x: size.width / 2, y: size.height - (compact ? 182 : 66))
                    .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .id(id)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(reduceMotion ? nil : BrowserMotion.spring, value: model.spaces.count)
    }
}

/// The space you just switched to. The icon rail is too narrow for a name,
/// so there it is the space's icon over a column of position dots.
private struct SpaceBanner: View {
    let space: BrowserSpaceRecord
    let index: Int
    let count: Int
    let compact: Bool
    let maxWidth: CGFloat

    var body: some View {
        if compact {
            VStack(spacing: 5) {
                Image(systemName: space.icon).font(.system(size: 13, weight: .medium))
                VStack(spacing: 3) {
                    ForEach(0..<min(count, 6), id: \.self) { position in
                        Capsule().fill(Color.primary.opacity(position == index ? 0.6 : 0.2))
                            .frame(width: 4, height: position == index ? 9 : 4)
                    }
                }
            }
            .padding(.vertical, 9)
            .frame(width: 32)
            .glassEffect(.regular, in: Capsule())
            .accessibilityLabel(space.name)
        } else {
            Label(space.name, systemImage: space.icon)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 12).frame(height: 30)
                .frame(maxWidth: maxWidth)
                .glassEffect(.regular, in: Capsule())
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Back, forward and reload in one glass capsule (Pico 427:2156 / 427:2242).
private struct NavigationCluster: View {
    let controller: BrowserController
    let vertical: Bool
    private var model: BrowserModel { controller.model }

    // Pico 438:1239 (84×32: 12pt sides, 8pt gaps) and 427:2256 (32×88: 8pt ends, 6pt gaps).
    private static let glyph = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.85) : NSColor(white: 0.15, alpha: 0.8)
    })

    var body: some View {
        let tab = model.selectedTab
        let loading = tab?.isLoading == true
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            if vertical {
                reload(loading)
                divider
            }
            button("chevron.left", L10n.string("Back"), L10n.string("Back") + "  ⌘[", width: 10,
                   enabled: tab?.canGoBack == true) { model.goBack() }
            button("chevron.right", L10n.string("Forward"), L10n.string("Forward") + "  ⌘]", width: 10,
                   enabled: tab?.canGoForward == true) { model.goForward() }
            if !vertical { divider; reload(loading) }
        }
        .padding(vertical ? .vertical : .horizontal, vertical ? 8 : 12)
        .frame(width: vertical ? 32 : nil, height: vertical ? nil : 32)
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.08))
            .frame(width: vertical ? 8 : 1, height: vertical ? 1 : 8)
    }

    private func reload(_ loading: Bool) -> some View {
        button(loading ? "xmark" : "arrow.clockwise", loading ? L10n.string("Stop Loading") : L10n.string("Reload"),
               loading ? L10n.string("Stop Loading") : L10n.string("Reload") + "  ⌘R", width: 16,
               enabled: model.selectedTab?.hasWebContent == true) {
            if loading { model.stopLoading() } else { model.reload() }
        }
        .contentTransition(.symbolEffect(.replace))
    }

    /// The glyph keeps the design's footprint; the hit area grows to the
    /// capsule's full thickness and halfway into the gaps around it.
    private func button(_ symbol: String, _ label: String, _ help: String, width: CGFloat,
                        enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Self.glyph)
                .frame(width: vertical ? 16 : width, height: vertical ? 18 : 32)
                .frame(width: vertical ? 32 : nil)
                .contentShape(Rectangle().inset(by: vertical ? -3 : -4))
        }
        .buttonStyle(PressSpringStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
        .help(help)
    }
}

private struct LibraryButton: View {
    let controller: BrowserController
    @ObservedObject private var downloads = ChromiumDownloadCoordinator.shared

    var body: some View {
        let updater = BrowserUpdater.shared
        let active = downloads.records.filter { $0.state.isActive }
        GlassSymbolButton("rectangle.stack", label: L10n.string("Library"), help: L10n.string("Library") + "  ⇧⌘L",
                          size: BrowserDesign.bottomButtonSize, symbolSize: 12, symbolWeight: .regular) {
            controller.model.openNativePage(.library(updater.showsButton ? .updates : active.isEmpty ? .all : .downloads))
        }
        .overlay(alignment: .topTrailing) {
            if updater.showsButton {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    .overlay { Circle().strokeBorder(.background, lineWidth: 1.5) }
                    .offset(x: 1, y: -1)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay {
            if !active.isEmpty {
                DownloadRing(records: active).allowsHitTesting(false).transition(.opacity)
            }
        }
        .animation(BrowserMotion.spring, value: updater.showsButton)
        .animation(BrowserMotion.spring, value: active.isEmpty)
    }
}

private struct DownloadRing: View {
    let records: [ChromiumDownloadRecord]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let total = records.reduce(Int64(0)) { $0 + $1.totalBytes }
            let received = records.reduce(Int64(0)) { $0 + min($1.receivedBytes, $1.totalBytes) }
            Circle()
                .trim(from: 0, to: total > 0 ? CGFloat(received) / CGFloat(total) : 0.25)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: BrowserDesign.bottomButtonSize + 2, height: BrowserDesign.bottomButtonSize + 2)
                .animation(BrowserMotion.spring, value: received)
        }
    }
}

/// One dot per space (Pico 438:1225); the active one is a capsule.
private struct SpaceDots: View {
    let controller: BrowserController
    @Binding var editingSpace: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var model: BrowserModel { controller.model }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(model.spaces) { space in
                let active = space.id == model.activeSpaceID
                Capsule()
                    .fill(Color.primary.opacity(active ? 0.55 : 0.2))
                    .frame(width: active ? 14 : 5, height: 5)
                    .frame(height: 20)
                    .contentShape(Rectangle().inset(by: -3))
                    .onTapGesture { withAnimation(reduceMotion ? nil : BrowserMotion.spring) { model.switchSpace(to: space.id) } }
                    .help(space.name)
                    .popover(isPresented: Binding(get: { editingSpace == space.id }, set: { if !$0 { editingSpace = nil } }),
                             arrowEdge: .top) {
                        SpaceEditor(controller: controller, space: space) { editingSpace = nil }
                    }
                    .contextMenu {
                        Button(L10n.string("Edit Space…"), systemImage: "pencil") { editingSpace = space.id }
                        Button(L10n.string("New Space"), systemImage: "plus") {
                            withAnimation(BrowserMotion.spring) { model.newSpace() }
                            editingSpace = model.activeSpaceID
                        }
                        Divider()
                        Button(L10n.string("Delete Space"), systemImage: "trash", role: .destructive) { confirmDelete(space) }
                            .disabled(model.spaces.count < 2)
                    }
                    .accessibilityElement()
                    .accessibilityLabel(space.name)
                    .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
            }
        }
        .animation(reduceMotion ? nil : BrowserMotion.spring, value: model.activeSpaceID)
    }

    private func confirmDelete(_ space: BrowserSpaceRecord) {
        let alert = NSAlert()
        alert.messageText = L10n.format("Delete “%@”?", space.name)
        alert.informativeText = L10n.string("Its pinned items and groups are removed, and its tabs close.")
        alert.addButton(withTitle: L10n.string("Delete Space"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            withAnimation(BrowserMotion.spring) { model.deleteSpace(space.id) }
        }
    }
}

private struct SpaceEditor: View {
    let controller: BrowserController
    let space: BrowserSpaceRecord
    let done: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: space.icon).frame(width: 18)
                TextField(L10n.string("Space Name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { controller.model.spaceStore.updateSpace(space.id, name: name); done() }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 6), spacing: 6) {
                ForEach(BrowserSpaceStore.iconChoices, id: \.self) { icon in
                    Button { controller.model.spaceStore.updateSpace(space.id, icon: icon) } label: {
                        Image(systemName: icon).font(.system(size: 13)).frame(width: 28, height: 28)
                            .background(Color.primary.opacity(space.icon == icon ? 0.14 : 0.04), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button(L10n.string("Done")) { controller.model.spaceStore.updateSpace(space.id, name: name); done() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 230)
        .onAppear { name = space.name }
    }
}
