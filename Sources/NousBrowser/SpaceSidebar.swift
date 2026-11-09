import AppKit
import SwiftUI

// The sidebar after Pico 427:2156 / 427:2242 / 438:1225 and Dia/Arc:
// pinned tiles, folders, ordinary tabs; one horizontally paged list per space
// (two-finger swipe to switch); back/forward/reload in one glass control.

enum SidebarMetrics {
    /// The icon rail moves its top controls down to make room for the
    /// window buttons when they are shown.
    static let compactWindowButtonsShift: CGFloat = 30
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

/// The latest measured frames. Deliberately not observable: rows move on
/// every frame of a scroll, a group opening, a space switch or a sidebar
/// resize, and re-rendering the whole sidebar for each of those changes is
/// what made them stutter. Only drag and drop and tooltips read the frames,
/// and only at the moment they need them.
@MainActor
final class SidebarFrameStore {
    var values: [SidebarFrameID: CGRect] = [:]
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
    /// Where the item started; a tab row cannot be re-parented while its own
    /// drag gesture is running (SwiftUI would end the gesture with the view).
    var origin: SidebarDropTarget? = nil

    /// The drop moves the item to another container (another group, in or
    /// out of a group, between pins and the list). Its view would be rebuilt
    /// there mid-drag, ending the gesture and leaving the drag stuck, so the
    /// list stays put and shows an insertion mark instead.
    var changesContainer: Bool {
        guard let origin else { return false }
        if target.section != origin.section { return true }
        if case .tab = item { return target.groupID != origin.groupID }
        return false
    }
}

// MARK: - Sidebar

struct BrowserSidebar: View {
    let controller: BrowserController
    let tooltip: SidebarTabTooltipState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var frameStore = SidebarFrameStore()
    private var frames: [SidebarFrameID: CGRect] { frameStore.values }
    @State private var drag: SidebarDragState?
    /// Horizontal travel of a two-finger swipe in progress, in points.
    @State private var swipe = SpaceSwipeState()
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
                    let lights = controller.appearance.showsWindowButtons
                    SidebarEdgeGlass(edge: .top,
                                     buttonCenters: compact ? [30] : [lights ? 102 : 28, geometry.size.width - 28],
                                     height: compact ? 124 + (lights ? SidebarMetrics.compactWindowButtonsShift : 0) : 84,
                                     controlCenterFromEdge: compact ? 48 + (lights ? SidebarMetrics.compactWindowButtonsShift : 0) : 28)
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

                SidebarControls(controller: controller, size: geometry.size, swipe: swipe,
                                editingSpace: $editingSpace, spaceBanner: spaceBanner, newGroup: newFolder)

                WindowDragArea()
                    .frame(height: BrowserDesign.inset)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .coordinateSpace(name: SidebarMetrics.coordinateSpace)
            .onPreferenceChange(SidebarFramePreference.self) { [frameStore] in frameStore.values = $0 }
            .background {
                SidebarDragCancellationMonitor(isEnabled: drag != nil, canCancel: drag != nil,
                                               onCancel: { cancelDrag() }, windowReference: dragWindow,
                                               onPointerRelease: { _ in finishStrandedDrag() }, onPointerPress: {})
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                SidebarTooltipDismissalMonitor(isEnabled: tooltip.isTracking, dismiss: tooltip.dismiss)
                    .frame(width: 0, height: 0)
            }
            .onChange(of: model.isSidebarCompact) { _, _ in cancelDrag(); tooltip.dismiss() }
            .onChange(of: model.activeSpaceID) { _, id in
                tooltip.dismiss()
                showBanner(id)
            }
        }
        .contextMenu {
            Group {
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
            // macOS 27 hides menu icons unless asked for.
            .labelStyle(.titleAndIcon)
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

    /// One page per space, side by side. Its position comes only from the
    /// active space (and a swipe in progress), never from a scroll view, so
    /// nothing that happens inside a space — a group opening or closing, a row
    /// animating — can move the pages. Two-finger horizontal swipes turn pages.
    private func spacePager(size: CGSize) -> some View {
        let spaces = model.spaces
        let index = CGFloat(spaces.firstIndex { $0.id == model.activeSpaceID } ?? 0)
        return HStack(spacing: 0) {
            ForEach(spaces) { space in
                let current = space.id == model.activeSpaceID
                SpaceColumn(controller: controller, space: space.id, layout: displayedLayout(for: space.id),
                            drag: drag, renamingGroup: $renamingGroup, tooltip: tooltip, frames: frameStore,
                            actions: dragActions(size: size))
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(current)
                    .accessibilityHidden(!current)
                    .id(space.id)
            }
        }
        .fixedSize()
        .offset(x: -index * size.width)
        .modifier(SpaceSwipeOffset(swipe: swipe))
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .animation(reduceMotion ? nil : BrowserMotion.spring, value: model.activeSpaceID)
        .background {
            SpaceSwipeMonitor(isEnabled: drag == nil && spaces.count > 1, width: size.width,
                              onBegin: { swipe.isTracking = true },
                              onChange: { delta in swipe.offset = resisted(swipe.offset + delta, index: Int(index), count: spaces.count, width: size.width) },
                              onEnd: { velocity in finishSwipe(index: Int(index), spaces: spaces, width: size.width, velocity: velocity) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Beyond the first or last space the pages stretch, then spring back.
    private func resisted(_ offset: CGFloat, index: Int, count: Int, width: CGFloat) -> CGFloat {
        let atStart = index == 0 && offset > 0
        let atEnd = index == count - 1 && offset < 0
        guard atStart || atEnd else { return max(-width, min(width, offset)) }
        let limit = width * 0.18
        return (offset > 0 ? 1 : -1) * limit * (1 - exp(-abs(offset) / limit))
    }

    private func finishSwipe(index: Int, spaces: [BrowserSpaceRecord], width: CGFloat, velocity: CGFloat) {
        var target = index
        if swipe.offset < -width * 0.25 || velocity < -600 { target = min(spaces.count - 1, index + 1) }
        else if swipe.offset > width * 0.25 || velocity > 600 { target = max(0, index - 1) }
        swipe.isTracking = false
        withAnimation(reduceMotion ? nil : BrowserMotion.spring) {
            swipe.offset = 0
            if target != index {
                tooltip.dismiss()
                model.switchSpace(to: spaces[target].id)
            }
        }
    }

    /// While dragging, the list shows where the item will land.
    private func displayedLayout(for space: UUID) -> SpaceLayout {
        let layout = model.layout(for: space)
        guard let drag, drag.space == space, !drag.isOutside else { return layout }
        return Self.displayed(layout, for: drag)
    }

    /// The list as drawn during a drag. Moving into or out of a group keeps the
    /// row where it is (the group shows an insertion mark), and so does dropping
    /// into a closed group (it lights up).
    private static func displayed(_ layout: SpaceLayout, for drag: SidebarDragState) -> SpaceLayout {
        if let id = drag.target.groupID, layout.group(id)?.isExpanded == false { return layout }
        if drag.changesContainer { return layout }
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
                                    target: start, size: frame.size, origin: start)
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

    /// Safety net: if SwiftUI dropped the drag gesture (its view was rebuilt),
    /// releasing the mouse still completes the drop instead of leaving the
    /// floating row stuck on screen.
    private func finishStrandedDrag() {
        DispatchQueue.main.async {
            guard let state = drag, !state.isOutside else { return }
            springLoad?.cancel()
            springLoad = nil
            NSCursor.arrow.set()
            withAnimation(reduceMotion ? nil : BrowserMotion.spring) {
                model.move(state.item, to: state.target, in: state.space)
                drag = nil
            }
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
        let layout = Self.displayed(model.layout(for: state.space), for: state)
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
    let frames: SidebarFrameStore
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
            .padding(.top, SidebarTabDragGeometry.topInset(isCompact: compact)
                     + (compact && controller.appearance.showsWindowButtons ? SidebarMetrics.compactWindowButtonsShift : 0))
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
            let pinning = if let drag, drag.space == space, drag.changesContainer, case .tab = drag.item,
                             drag.target.section == .pinned, drag.target.groupID == nil { true } else { false }
            let folderInsertion: Int? = if let drag, drag.space == space, drag.changesContainer, case .group = drag.item,
                                           drag.target.section == .pinned { drag.target.index - tiles.count } else { nil }
            if !tiles.isEmpty {
                PinnedGrid(controller: controller, space: space, ids: tiles, compact: compact,
                           draggedID: drag?.space == space ? drag?.item.id : nil, actions: actions)
                    .background {
                        RoundedRectangle(cornerRadius: SidebarMetrics.tileHeight / 2 + 4, style: .continuous)
                            .fill(Color.accentColor.opacity(pinning ? 0.12 : 0))
                            .overlay {
                                RoundedRectangle(cornerRadius: SidebarMetrics.tileHeight / 2 + 4, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(pinning ? 0.45 : 0), lineWidth: 1)
                            }
                            .padding(-4)
                    }
                    .animation(reduceMotion ? nil : BrowserMotion.interaction, value: pinning)
                    .padding(.bottom, folders.isEmpty ? 0 : 6)
            } else if isDraggingTab, !compact {
                Label(L10n.string("Drop to Pin"), systemImage: "pin")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(pinning ? Color.accentColor : .secondary)
                    .frame(maxWidth: .infinity).frame(height: SidebarMetrics.tileHeight)
                    .background(Capsule().fill(Color.accentColor.opacity(pinning ? 0.12 : 0)))
                    .background(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(pinning ? Color.accentColor : .secondary.opacity(0.5)))
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            ForEach(Array(folders.enumerated()), id: \.element.id) { index, group in
                folder(group, section: .pinned)
                    .overlay(alignment: .top) {
                        if folderInsertion == index { insertionMark.offset(y: -3) }
                    }
                    .overlay(alignment: .bottom) {
                        if folderInsertion == folders.count, index == folders.count - 1 { insertionMark.offset(y: 3) }
                    }
            }
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
            let insertion: Int? = if let drag, drag.space == space, drag.changesContainer,
                                     drag.target.section == .regular, drag.target.groupID == nil { drag.target.index } else { nil }
            ForEach(Array(layout.regular.enumerated()), id: \.element.id) { index, node in
                Group {
                    switch node {
                    case .tab(let id): tabRow(id, in: nil)
                    case .group(let group): folder(group, section: .regular)
                    }
                }
                .overlay(alignment: .top) {
                    if insertion == index { insertionMark.offset(y: -SidebarTabDragGeometry.rowSpacing / 2 - 1) }
                }
                .overlay(alignment: .bottom) {
                    if insertion == layout.regular.count, index == layout.regular.count - 1 {
                        insertionMark.offset(y: SidebarTabDragGeometry.rowSpacing / 2 + 1)
                    }
                }
            }
            // Pico 448:1297: a quiet “New Tab” row ends the list.
            SidebarNewTabRow(compact: compact, action: controller.newTab)
                .opacity(isDraggingTab ? 0 : 1)
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
        let insertion: Int? = if let drag, drag.space == space, drag.changesContainer, group.isExpanded,
                                 drag.target.groupID == group.id { drag.target.index } else { nil }
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
                    .overlay(alignment: .top) {
                        if insertion == visible.firstIndex(of: id) { insertionMark.offset(y: -SidebarTabDragGeometry.rowSpacing / 2 - 1) }
                    }
                    .overlay(alignment: .bottom) {
                        if insertion == visible.count, id == visible.last { insertionMark.offset(y: SidebarTabDragGeometry.rowSpacing / 2 + 1) }
                    }
                    // Leaving rows fade quickly, inside the group, while it closes.
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -8)),
                                            removal: .opacity.animation(.easeOut(duration: 0.12))))
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
            folderShape.fill(isTarget ? Color.accentColor.opacity(0.12)
                             : Color.primary.opacity(contained ? (colorScheme == .dark ? 0.06 : 0.045) : 0))
                .overlay { folderShape.strokeBorder(Color.accentColor.opacity(isTarget ? 0.45 : 0), lineWidth: 1) }
        }
        // Rows never draw outside their group while it opens or closes.
        .clipShape(contained || isTarget ? AnyShape(folderShape) : AnyShape(Rectangle()))
        .padding(.horizontal, contained || isTarget ? -SidebarMetrics.folderInset : 0)
        .sidebarFrame(.folderBody(group.id))
        .scaleEffect(isTarget && !group.isExpanded && !reduceMotion ? 1.02 : 1)
        .animation(reduceMotion ? nil : BrowserMotion.interaction, value: isTarget)
        .animation(reduceMotion ? nil : BrowserMotion.spring, value: contained)
        .padding(.vertical, contained ? 2 : 0)
        .opacity(dragged ? 0 : 1)
    }

    private var folderShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: (compact ? 18 : BrowserDesign.rowHeight / 2) + SidebarMetrics.folderInset,
                         style: .continuous)
    }

    private var insertionMark: some View {
        Capsule().fill(Color.accentColor).frame(height: 2)
            .padding(.leading, compact ? 4 : SidebarMetrics.folderIndent + 6).padding(.trailing, 6)
            .allowsHitTesting(false)
            .transition(.opacity)
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
                              if hovering, compact, drag == nil, let frame = frames.values[.tab(id)] {
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
        // Never more columns than pins, so a single row always spans the sidebar.
        return max(1, count <= 4 ? count : min(count, fitting, 6))
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
            Group {
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
            // macOS 27 hides menu icons unless asked for.
            .labelStyle(.titleAndIcon)
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
            Group {
            Button(L10n.string("Rename Group"), systemImage: "pencil", action: startRename)
            Button(L10n.string("Change Icon…"), systemImage: "face.smiling") { choosingIcon = true }
            Button(L10n.string(section == .pinned ? "Unpin Group" : "Pin Group"), systemImage: section == .pinned ? "pin.slash" : "pin") {
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
            // macOS 27 hides menu icons unless asked for.
            .labelStyle(.titleAndIcon)
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

/// The last row of the tab list: a plus and “New Tab” in secondary grey,
/// lifting to a soft capsule on hover like a tab row.
private struct SidebarNewTabRow: View {
    let compact: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    var body: some View {
        let label = L10n.string("New Tab")
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .regular))
                    .frame(width: 16, height: 16)
                if !compact {
                    Text(label)
                        .font(.system(size: 12, weight: .regular))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .foregroundStyle(Color.primary.opacity(hovered ? 0.8 : 0.55))
            .padding(.horizontal, compact ? 0 : 12)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .frame(height: BrowserDesign.rowHeight)
            .background(Color.white.opacity(colorScheme == .dark ? (hovered ? 0.08 : 0) : (hovered ? 0.5 : 0)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressSpringStyle())
        .onHover { value in withAnimation(reduceMotion ? nil : BrowserMotion.interaction) { hovered = value } }
        .help(label + "  ⌘T")
        .accessibilityLabel(label)
    }
}

private struct SidebarControls: View {
    let controller: BrowserController
    let size: CGSize
    let swipe: SpaceSwipeState
    @Binding var editingSpace: UUID?
    let spaceBanner: UUID?
    let newGroup: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var model: BrowserModel { controller.model }

    private func newSpace() {
        withAnimation(reduceMotion ? nil : BrowserMotion.spring) { model.newSpace() }
        editingSpace = model.activeSpaceID
    }

    var body: some View {
        let compact = model.isSidebarCompact
        let topLabel = L10n.string(compact ? "Expand Sidebar" : "Collapse Sidebar")
        let lights = controller.appearance.showsWindowButtons
        // With window buttons: they lead the top row (wide sidebar) or get a
        // row of their own above the controls (icon rail).
        let toggleX: CGFloat = lights && !compact ? 102 : compact ? 30 : 28
        let shift: CGFloat = lights && compact ? SidebarMetrics.compactWindowButtonsShift : 0
        ZStack(alignment: .topLeading) {
            if !compact {
                let dragStart = toggleX + 20
                WindowDragArea()
                    .frame(width: max(0, size.width - 56 - dragStart), height: BrowserDesign.buttonSize)
                    .position(x: (dragStart + size.width - 56) / 2, y: 28)
            }
            if lights {
                Group {
                    if compact { WindowTrafficLights(diameter: 12, spacing: 6) }
                    else { WindowTrafficLights() }
                }
                .position(x: compact ? 30 : 47, y: compact ? 24 : 28)
                .transition(.opacity)
            }
            GlassSymbolButton("sidebar.left", label: topLabel, help: topLabel + "  ⌘/",
                              symbolSize: BrowserDesign.topSymbolSize, symbolWeight: .medium) { model.toggleSidebar() }
                .position(x: toggleX, y: 28 + shift)
            SidebarNewMenuButton(controller: controller, newGroup: newGroup, newSpace: newSpace)
                .position(x: compact ? 30 : size.width - 28, y: compact ? 68 + shift : 28)

            NavigationCluster(controller: controller, vertical: compact)
                .position(x: compact ? 30 : BrowserDesign.inset + 42, y: compact ? size.height - 60 : size.height - 28)

            LibraryButton(controller: controller)
                .position(x: compact ? 30 : size.width - 28, y: compact ? size.height - 134 : size.height - 28)

            if !compact, model.spaces.count > 1 || editingSpace != nil {
                SpaceDots(controller: controller, swipe: swipe, pageWidth: size.width, editingSpace: $editingSpace)
                    .position(x: (BrowserDesign.inset + 84 + size.width - 46) / 2, y: size.height - 28)
                    .transition(.opacity)
            }
            // The wide sidebar's dots already follow a swipe; a banner arriving
            // after the pages settle read as an afterimage. The icon rail has
            // no dots, so it keeps its small indicator.
            if compact, let id = spaceBanner, let space = model.spaces.first(where: { $0.id == id }), model.spaces.count > 1 {
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
struct SpaceDots: View {
    let controller: BrowserController
    let swipe: SpaceSwipeState
    let pageWidth: CGFloat
    @Binding var editingSpace: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: UUID?
    private var model: BrowserModel { controller.model }

    /// Like the iOS page control: never more than this many dots, so a
    /// narrow sidebar never overflows. Swiping still reaches every space.
    static let maximumVisible = 4
    static let dot: CGFloat = 5
    static let spacing: CGFloat = 5
    /// How much wider the current space's capsule is than a dot.
    static let stretch: CGFloat = 9

    /// The run of spaces shown when the pages are at rest.
    static func visibleRange(count: Int, active: Int, limit: Int = maximumVisible) -> Range<Int> {
        let start = Int(windowStart(count: count, progress: CGFloat(active), limit: limit))
        return start..<(start + min(count, limit))
    }

    /// The first visible slot, continuous so the window glides with a swipe.
    static func windowStart(count: Int, progress: CGFloat, limit: Int = maximumVisible) -> CGFloat {
        guard count > limit else { return 0 }
        return min(max(0, progress - CGFloat(limit - 2)), CGFloat(count - limit))
    }

    /// How much of the “current” capsule dot `index` holds at a fractional
    /// position between spaces: 1 at rest on it, shared with a neighbour mid-swipe.
    static func weight(_ index: Int, progress: CGFloat) -> CGFloat {
        max(0, 1 - abs(CGFloat(index) - progress))
    }

    /// Leading edge of dot `index`.
    static func leading(_ index: Int, progress: CGFloat) -> CGFloat {
        var x = CGFloat(index) * (dot + spacing)
        for earlier in 0..<index { x += stretch * weight(earlier, progress: progress) }
        return x
    }

    /// Leading edge at a fractional slot, for the sliding window.
    static func leading(slot: CGFloat, progress: CGFloat) -> CGFloat {
        let low = Int(slot.rounded(.down))
        let fraction = slot - CGFloat(low)
        let a = leading(low, progress: progress)
        return fraction == 0 ? a : a + (leading(low + 1, progress: progress) - a) * fraction
    }

    var body: some View {
        let spaces = model.spaces
        let count = spaces.count
        let active = spaces.firstIndex { $0.id == model.activeSpaceID } ?? 0
        // Follows the fingers: the swipe offset is how far the pages have moved.
        let raw = CGFloat(active) - swipe.offset / max(1, pageWidth)
        let progress = min(max(0, raw), CGFloat(max(0, count - 1)))
        let start = Self.windowStart(count: count, progress: progress)
        let visible = min(count, Self.maximumVisible)
        let width = CGFloat(visible) * (Self.dot + Self.spacing) - Self.spacing + Self.stretch
        let origin = Self.leading(slot: start, progress: progress)
        let moreBefore = min(1, start)
        let moreAfter = min(1, CGFloat(count - visible) - start)
        ZStack(alignment: .leading) {
            ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                let weight = Self.weight(index, progress: progress)
                let dotWidth = Self.dot + Self.stretch * weight
                let x = Self.leading(index, progress: progress) - origin
                let center = x + dotWidth / 2
                // Fade out beyond the window; shrink at an edge with more spaces past it.
                let inside = min(1, max(0, min(center + 2, width + 2 - center) / 4))
                let nearLeft = max(0, 1 - center / 10) * moreBefore
                let nearRight = max(0, 1 - (width - center) / 10) * moreAfter
                let scale = 1 - 0.32 * max(nearLeft, nearRight) * (1 - weight)
                dot(space, weight: weight, width: dotWidth, scale: scale)
                    .opacity(inside)
                    .allowsHitTesting(inside > 0.5)
                    .accessibilityHidden(inside < 0.5)
                    .offset(x: x)
            }
        }
        .frame(width: width, height: 20, alignment: .leading)
        .animation(reduceMotion ? nil : BrowserMotion.interaction, value: hovered)
    }

    private func dot(_ space: BrowserSpaceRecord, weight: CGFloat, width: CGFloat, scale: CGFloat) -> some View {
        let isHovered = hovered == space.id
        let active = space.id == model.activeSpaceID
        let base = 0.2 + 0.35 * weight
        return Capsule()
            .fill(Color.primary.opacity(isHovered ? base + 0.2 : base))
            .frame(width: width, height: Self.dot)
            .scaleEffect(isHovered && weight < 0.5 ? 1.3 : scale)
            .frame(width: width, height: 20)
            .contentShape(Rectangle().inset(by: -2.5))
            .onHover { inside in
                if inside { hovered = space.id } else if hovered == space.id { hovered = nil }
            }
            .onTapGesture { withAnimation(reduceMotion ? nil : BrowserMotion.spring) { model.switchSpace(to: space.id) } }
            .help(space.name)
            .popover(isPresented: Binding(get: { editingSpace == space.id }, set: { if !$0 { editingSpace = nil } }),
                     arrowEdge: .top) {
                SpaceEditor(controller: controller, space: space) { editingSpace = nil }
            }
            .contextMenu {
                Group {
                Button(L10n.string("Edit Space…"), systemImage: "pencil") { editingSpace = space.id }
                Button(L10n.string("New Space"), systemImage: "plus") {
                    withAnimation(BrowserMotion.spring) { model.newSpace() }
                    editingSpace = model.activeSpaceID
                }
                Divider()
                Button(L10n.string("Delete Space"), systemImage: "trash", role: .destructive) { confirmDelete(space) }
                    .disabled(model.spaces.count < 2)
                }
                // macOS 27 hides menu icons unless asked for.
                .labelStyle(.titleAndIcon)
            }
            .accessibilityElement()
            .accessibilityLabel(space.name)
            .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
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

/// A swipe in progress. Kept out of the sidebar's own state so each trackpad
/// event redraws only the pager's offset, not every space's list.
@MainActor
@Observable
final class SpaceSwipeState {
    var offset: CGFloat = 0
    var isTracking = false
}

/// Moves the pages while drawing only: row frames (used for drag and drop)
/// do not change, so a swipe does not re-measure the lists.
private struct SpaceSwipeOffset: ViewModifier {
    let swipe: SpaceSwipeState

    func body(content: Content) -> some View {
        let offset = swipe.offset
        content
            .visualEffect { effect, _ in effect.offset(x: offset) }
            .allowsHitTesting(!swipe.isTracking)
    }
}

/// Two-finger horizontal swipes over the sidebar. Vertical scrolling and
/// momentum after the fingers lift go on to the lists as usual.
private struct SpaceSwipeMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let width: CGFloat
    let onBegin: () -> Void
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.isEnabled = isEnabled
        view.onBegin = onBegin
        view.onChange = onChange
        view.onEnd = onEnd
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var isEnabled = false
        var onBegin: (() -> Void)?
        var onChange: ((CGFloat) -> Void)?
        var onEnd: ((CGFloat) -> Void)?
        private var monitor: Any?
        private enum Phase { case idle, undecided, horizontal, vertical }
        private var phase = Phase.idle
        private var undecidedX: CGFloat = 0
        private var undecidedY: CGFloat = 0
        private var samples: [(time: TimeInterval, dx: CGFloat)] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.consumes(event) ?? false }
                return consumed ? nil : event
            }
        }

        func stop() {
            phaselessEnd?.cancel()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// True when the event belongs to a page swipe.
        private func consumes(_ event: NSEvent) -> Bool {
            // Momentum after the fingers lift belongs to the finished swipe.
            guard event.hasPreciseScrollingDeltas else { return false }
            // Some input utilities (and screen-control tools) re-post
            // trackpad scrolling without gesture phases. Those streams are
            // read as gestures too: one starts after a pause and ends when the
            // events stop.
            if event.phase.isEmpty && event.momentumPhase.isEmpty { return consumesPhaseless(event) }
            if !event.momentumPhase.isEmpty { return swallowMomentum }
            if event.phase.contains(.began) {
                swallowMomentum = false
                guard isEnabled, event.window === window, bounds.contains(convert(event.locationInWindow, from: nil)) else {
                    phase = .idle
                    return false
                }
                phase = .undecided
                undecidedX = 0
                undecidedY = 0
                samples = []
            }
            let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            switch phase {
            case .idle, .vertical:
                if ended { phase = .idle }
                return false
            case .undecided:
                undecidedX += event.scrollingDeltaX
                undecidedY += event.scrollingDeltaY
                if abs(undecidedX) > 6 || abs(undecidedY) > 6 {
                    phase = abs(undecidedX) > abs(undecidedY) * 1.4 ? .horizontal : .vertical
                    if phase == .horizontal {
                        onBegin?()
                        track(undecidedX)
                    }
                }
                if ended {
                    if phase == .horizontal { finish() } else { phase = .idle }
                }
                return phase == .horizontal || (ended && swallowMomentum)
            case .horizontal:
                if ended { finish() } else { track(event.scrollingDeltaX) }
                return true
            }
        }

        private var swallowMomentum = false
        private var lastPhaselessEvent: TimeInterval = 0
        private var phaselessEnd: DispatchWorkItem?

        private func consumesPhaseless(_ event: NSEvent) -> Bool {
            let fresh = event.timestamp - lastPhaselessEvent > 0.2
            lastPhaselessEvent = event.timestamp
            if fresh {
                if phase == .horizontal { finish() }
                guard isEnabled, event.window === window, bounds.contains(convert(event.locationInWindow, from: nil)) else {
                    phase = .idle
                    return false
                }
                phase = .undecided
                undecidedX = 0
                undecidedY = 0
                samples = []
            }
            phaselessEnd?.cancel()
            let end = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.phase == .horizontal { self.finish() } else { self.phase = .idle }
                    self.swallowMomentum = false
                }
            }
            phaselessEnd = end
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: end)
            switch phase {
            case .idle, .vertical:
                return false
            case .undecided:
                undecidedX += event.scrollingDeltaX
                undecidedY += event.scrollingDeltaY
                if abs(undecidedX) > 6 || abs(undecidedY) > 6 {
                    phase = abs(undecidedX) > abs(undecidedY) * 1.4 ? .horizontal : .vertical
                    if phase == .horizontal {
                        onBegin?()
                        track(undecidedX)
                    }
                }
                return phase == .horizontal
            case .horizontal:
                track(event.scrollingDeltaX)
                return true
            }
        }

        private func track(_ dx: CGFloat) {
            let now = ProcessInfo.processInfo.systemUptime
            samples.append((now, dx))
            samples.removeAll { now - $0.time > 0.12 }
            onChange?(dx)
        }

        private func finish() {
            let span = max(0.016, (samples.last?.time ?? 0) - (samples.first?.time ?? 0))
            let velocity = samples.reduce(0) { $0 + $1.dx } / span
            phase = .idle
            swallowMomentum = true
            samples = []
            onEnd?(velocity)
        }
    }
}
