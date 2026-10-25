import AppKit
import SwiftUI

// Measurements come from Pico / Nous Browser, 368:6439 and 370:10995.
enum BrowserDesign {
    static let inset: CGFloat = 16
    static let buttonSize: CGFloat = 36
    static let rowHeight: CGFloat = 36
    static let windowRadius: CGFloat = 28
    static let pageRadius: CGFloat = 18
}

enum BrowserMotion {
    static let spring = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let interaction = Animation.spring(response: 0.18, dampingFraction: 0.72)
    /// Tab selection should feel immediate; web content itself swaps without animation.
    static let tabSwitch = Animation.spring(response: 0.14, dampingFraction: 0.90)
}

struct BrowserShell: View {
    @Bindable var controller: BrowserController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var model: BrowserModel { controller.model }
    @State private var isResizingSidebar = false
    @State private var isHoveringDivider = false

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = CGFloat(SidebarSizing.effectiveWidth(preferred: model.sidebarWidth, windowWidth: geometry.size.width))
            let maximumWidth = CGFloat(SidebarSizing.effectiveWidth(preferred: SidebarSizing.maximumWidth, windowWidth: geometry.size.width))
            // Only the root mask clips the window perimeter. A second rounded
            // mask blends the light backing into dark webpage edges.
            let pageShape = UnevenRoundedRectangle(
                topLeadingRadius: model.isSidebarVisible ? BrowserDesign.pageRadius : 0,
                bottomLeadingRadius: model.isSidebarVisible ? BrowserDesign.pageRadius : 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
            ZStack(alignment: .leading) {
                WindowMaterial()
                    .overlay(colorScheme == .dark ? Color(white: 0.12).opacity(0.70) : Color.white.opacity(0.76))

                BrowserSidebar(controller: controller)
                    .frame(width: sidebarWidth)
                    .offset(x: model.isSidebarVisible ? 0 : -sidebarWidth)
                    .opacity(model.isSidebarVisible ? 1 : 0)
                    .allowsHitTesting(model.isSidebarVisible)
                    .accessibilityHidden(!model.isSidebarVisible)

                page
                    .clipShape(pageShape)
                    .overlay {
                        if model.isSidebarVisible {
                            pageShape
                                .strokeBorder((colorScheme == .dark ? Color.white : Color.black).opacity(0.08), lineWidth: 0.6)
                                .mask(alignment: .leading) {
                                    Rectangle().frame(width: BrowserDesign.pageRadius + 1)
                                }
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.leading, model.isSidebarVisible ? sidebarWidth : 0)

                if model.isSidebarVisible {
                    SidebarResizeHandle(width: sidebarWidth, onBegin: {
                        isResizingSidebar = true
                    }, onResize: { width in
                        // Direct manipulation follows the pointer without animation lag.
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { model.resizeSidebar(to: min(width, maximumWidth)) }
                    }, onEnd: {
                        isResizingSidebar = false
                        model.persistSession()
                    }, onReset: {
                        withAnimation(reduceMotion ? nil : BrowserMotion.spring) { model.resetSidebarWidth() }
                    }, onHover: { value in
                        withAnimation(reduceMotion ? nil : BrowserMotion.interaction) { isHoveringDivider = value }
                    })
                    .frame(width: 10)
                    .background {
                        Capsule()
                            .fill(.primary.opacity(isHoveringDivider || isResizingSidebar ? 0.22 : 0))
                            .frame(width: 3, height: 32)
                            .allowsHitTesting(false)
                    }
                    .offset(x: sidebarWidth - 5)
                    .transition(.opacity)
                    .zIndex(1)
                }

                if controller.isAddressPresented {
                    Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08)
                        .contentShape(Rectangle())
                        .onTapGesture { controller.dismissAddress() }
                        .transition(.opacity)
                    AddressPalette(controller: controller)
                        .frame(width: min(560, geometry.size.width - 48))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, min(92, geometry.size.height * 0.13))
                        .transition(.asymmetric(insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity), removal: .opacity))
                        .zIndex(2)
                }

                if let toast = controller.toast {
                    Label(toast, systemImage: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .glassEffect(.regular, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 22)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                        .zIndex(3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: BrowserDesign.windowRadius, style: .continuous))
            .animation(reduceMotion || isResizingSidebar ? nil : BrowserMotion.spring, value: sidebarWidth)
            .animation(reduceMotion ? nil : BrowserMotion.spring, value: model.isSidebarVisible)
            .animation(reduceMotion ? nil : BrowserMotion.spring, value: controller.isAddressPresented)
            .animation(reduceMotion ? nil : BrowserMotion.tabSwitch, value: model.selectedTabID)
        }
        .ignoresSafeArea()
        .scrollIndicators(.hidden)
        .onExitCommand { if controller.isAddressPresented { controller.dismissAddress() } }
        .sheet(isPresented: Binding(get: { controller.passwords.isPresented },
                                    set: { controller.passwords.isPresented = $0 })) {
            BrowserPasswordsSheet(controller: controller.passwords)
        }
    }

    @ViewBuilder private var page: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .textBackgroundColor)
            WebViewDeck(tabs: model.tabs, selectedID: model.selectedTab?.hasWebContent == true ? model.selectedTabID : nil)
            if let tab = model.selectedTab, tab.hasWebContent {
                if let error = tab.errorDescription {
                    PageErrorView(message: error) { model.reload() }
                }
                if tab.isLoading {
                    GeometryReader { size in
                        Capsule().fill(.primary.opacity(0.5))
                            .frame(width: max(24, size.size.width * tab.estimatedProgress), height: 2)
                            .animation(BrowserMotion.spring, value: tab.estimatedProgress)
                    }
                    .frame(height: 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            } else {
                NewTabView(controller: controller)
            }
            // A narrow, transparent drag target keeps the content-only window movable.
            WindowDragArea().frame(height: 6)
        }
        .overlay(alignment: .bottomTrailing) {
            if controller.passwords.canFill && !controller.isAddressPresented {
                Button(L10n.string("Fill Password"), systemImage: "key.fill", action: controller.passwords.presentFill)
                    .buttonStyle(.bordered)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .padding(18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : BrowserMotion.spring, value: controller.passwords.canFill)
    }
}

private struct BrowserSidebar: View {
    let controller: BrowserController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var model: BrowserModel { controller.model }
    @State private var draftOrder: [UUID] = []
    @State private var dragSession: SidebarTabDragSession?
    @State private var blockedGestureID: UUID?
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var scrollPosition = ScrollPosition(y: 0)
    @State private var scrollMetrics = SidebarScrollMetrics()
    @State private var lastEdgeScrollUptime: TimeInterval = 0

    private var pinnedIDs: Set<UUID> { Set(model.tabs.filter(\.isPinned).map(\.id)) }
    private var orderedTabs: [BrowserTab] {
        guard dragSession != nil, draftOrder.count == model.tabs.count else { return model.tabs }
        let tabsByID = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0) })
        let tabs = draftOrder.compactMap { tabsByID[$0] }
        return tabs.count == model.tabs.count ? tabs : model.tabs
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Insets belong to the scrolling document, so rows can travel
                // behind both floating button groups instead of hitting a shelf.
                ScrollView {
                    VStack(spacing: SidebarTabDragGeometry.rowSpacing) {
                        ForEach(orderedTabs) { tab in
                            BrowserTabRow(tab: tab, selected: model.selectedTabID == tab.id,
                                          select: { withAnimation(reduceMotion ? nil : BrowserMotion.tabSwitch) { model.selectTab(tab.id) } },
                                          close: { withAnimation(reduceMotion ? nil : BrowserMotion.spring) { model.closeTab(tab.id) } },
                                          copy: { controller.copyURL(tab) },
                                          newTab: controller.newTab,
                                          duplicate: {
                                              withAnimation(reduceMotion ? nil : BrowserMotion.spring) { model.duplicateTab(tab.id) }
                                              if model.selectedTab?.url == nil { controller.showAddress() }
                                          },
                                          togglePin: {
                                              withAnimation(reduceMotion ? nil : BrowserMotion.spring) {
                                                  model.togglePin(tab.id)
                                                  if tab.isPinned { scrollPosition.scrollTo(edge: .top) }
                                              }
                                          },
                                          editAddress: controller.showAddress,
                                          dragChanged: { updateDrag(tab.id, value: $0, viewportHeight: geometry.size.height) },
                                          dragEnded: { endDrag(tab.id, value: $0, viewport: geometry.size) },
                                          dragCancelled: { gestureStopped(tab.id) },
                                          moveUp: { moveAccessibly(tab.id, by: -1) },
                                          moveDown: { moveAccessibly(tab.id, by: 1) },
                                          canMoveUp: canMove(tab.id, by: -1),
                                          canMoveDown: canMove(tab.id, by: 1))
                            .background {
                                GeometryReader { rowGeometry in
                                    Color.clear.preference(key: SidebarTabFramePreference.self,
                                                           value: [tab.id: rowGeometry.frame(in: .named(SidebarTabDragGeometry.coordinateSpace))])
                                }
                            }
                            .opacity(dragSession?.id == tab.id ? 0 : 1)
                            .transition(.asymmetric(insertion: .identity, removal: .scale(scale: 0.92).combined(with: .opacity)))
                        }
                    }
                    .padding(.horizontal, BrowserDesign.inset)
                    .padding(.vertical, SidebarTabDragGeometry.contentInset)
                    // Rows sit above this background, so a row press can only drag
                    // the tab; the empty list area below the rows moves the window.
                    .frame(minHeight: geometry.size.height, alignment: .top)
                    .windowDragBackground()
                }
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: SidebarScrollMetrics.self) { SidebarScrollMetrics($0) } action: { previous, metrics in
                    if dragSession?.isSettling == false,
                       Int(previous.offsetY / 32) != Int(metrics.offsetY / 32) || previous.maximumOffsetY != metrics.maximumOffsetY {
                        SidebarDragDiagnostics.log("scroll.geometry offset=\(metrics.offsetY) max=\(metrics.maximumOffsetY)")
                    }
                    scrollMetrics = metrics
                    updateDraftDestination()
                }
                .onPreferenceChange(SidebarTabFramePreference.self) { rowFrames = $0 }
                .scrollIndicators(.hidden)
                .clipped()
                .animation(reduceMotion ? nil : BrowserMotion.spring, value: model.tabs.map(\.id))
                .animation(reduceMotion ? nil : BrowserMotion.spring, value: draftOrder)

                VStack(spacing: 0) {
                    SidebarEdgeGlass(edge: .top,
                                     buttonCenters: [34, geometry.size.width - 34], height: 88)
                    Spacer(minLength: 0)
                    SidebarEdgeGlass(edge: .bottom,
                                     buttonCenters: [34, 78, geometry.size.width - 34], height: 88)
                }
                // Continue the glass behind the page's corner cutouts without
                // expanding the sidebar's content or interactive area.
                .frame(width: geometry.size.width + BrowserDesign.pageRadius * 2)
                .frame(width: geometry.size.width, alignment: .leading)
                .allowsHitTesting(false)

                if let session = dragSession, let tab = model.tabs.first(where: { $0.id == session.id }) {
                    SidebarFloatingTab(tab: tab, isSettling: session.isSettling)
                        .frame(width: max(0, geometry.size.width - BrowserDesign.inset * 2))
                        .position(session.center)
                        .transaction { if !session.isSettling { $0.animation = nil } }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 0) {
                    HStack {
                        GlassSymbolButton("sidebar.left", label: L10n.string("Hide Sidebar"), help: L10n.string("Hide Sidebar") + "  ⌘/") {
                            withAnimation(BrowserMotion.spring) { model.toggleSidebar() }
                        }
                        Spacer()
                        GlassSymbolButton("plus", label: L10n.string("New Tab"), help: L10n.string("New Tab") + "  ⌘T", action: controller.newTab)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        GlassSymbolButton("chevron.left", label: L10n.string("Back"), help: L10n.string("Back") + "  ⌘← / ⌘[") { model.goBack() }
                            .disabled(model.selectedTab?.canGoBack != true)
                        GlassSymbolButton("chevron.right", label: L10n.string("Forward"), help: L10n.string("Forward") + "  ⌘→ / ⌘]") { model.goForward() }
                            .disabled(model.selectedTab?.canGoForward != true)
                        Spacer(minLength: 0)
                        GlassSymbolButton(model.selectedTab?.isLoading == true ? "xmark" : "arrow.trianglehead.clockwise.rotate.90",
                                          label: model.selectedTab?.isLoading == true ? L10n.string("Stop Loading") : L10n.string("Reload"), help: L10n.string("Reload") + "  ⌘R") {
                            if model.selectedTab?.isLoading == true { model.stopLoading() } else { model.reload() }
                        }
                    }
                }
                .padding(BrowserDesign.inset)

                // Keep a clear drag target without blocking rows or the wheel
                // in the transparent gaps between the floating controls.
                WindowDragArea()
                    .frame(height: 8)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .coordinateSpace(name: SidebarTabDragGeometry.coordinateSpace)
            .background {
                ZStack {
                    SidebarDragCancellationMonitor(isEnabled: dragSession != nil || blockedGestureID != nil,
                                                   canCancel: dragSession?.isSettling == false,
                                                   onCancel: { cancelDrag() },
                                                   onPointerRelease: { blockedGestureID = nil })
                    SidebarEdgeAutoScrollDriver(isActive: dragSession?.isSettling == false,
                                                onTick: { autoScrollTick(viewportHeight: geometry.size.height, tick: $0) })
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
            .onChange(of: model.tabs.map(\.id)) { _, _ in cancelIfModelChanged() }
            .onChange(of: pinnedIDs) { _, _ in cancelIfModelChanged() }
            .onChange(of: model.isSidebarVisible) { _, visible in if !visible { cancelDrag() } }
            .onChange(of: controller.isAddressPresented) { _, presented in if presented { cancelDrag() } }
            .onChange(of: geometry.size) { _, _ in cancelDrag() }
            .onDisappear { clearDrag() }
        }
        .contextMenu {
            Button(L10n.string("Open Address…"), systemImage: "magnifyingglass", action: controller.showAddress)
            Button(L10n.string("New Tab"), systemImage: "plus", action: controller.newTab)
            Button(L10n.string("New Window"), systemImage: "macwindow.badge.plus", action: controller.newWindow)
            Divider()
            Button(L10n.string("Minimize Window"), systemImage: "minus") { NSApp.keyWindow?.miniaturize(nil) }
            Button(L10n.string("Enter Full Screen"), systemImage: "arrow.up.left.and.arrow.down.right") { NSApp.keyWindow?.toggleFullScreen(nil) }
            Button(L10n.string("Close Window"), systemImage: "xmark.rectangle", action: controller.closeWindow)
        }
    }

    private func updateDrag(_ id: UUID, value: DragGesture.Value, viewportHeight: CGFloat, isFinal: Bool = false) {
        guard blockedGestureID != id else { return }
        if dragSession == nil {
            guard let rect = rowFrames[id], model.tabs.contains(where: { $0.id == id }) else { return }
            let order = model.tabs.map(\.id)
            lastEdgeScrollUptime = 0
            draftOrder = order
            dragSession = SidebarTabDragSession(id: id, originalOrder: order, pinnedIDs: pinnedIDs,
                                                sourceRect: rect, grabOffsetY: value.startLocation.y - rect.minY,
                                                initialPointer: value.startLocation, pointer: value.location,
                                                center: CGPoint(x: rect.midX, y: rect.midY))
            SidebarDragDiagnostics.log("drag.begin rows=\(order.count) startY=\(value.startLocation.y) rowY=\(rect.minY) offset=\(scrollMetrics.offsetY) max=\(scrollMetrics.maximumOffsetY)")
            NSCursor.closedHand.set()
        }
        guard var session = dragSession, session.id == id, !session.isSettling else { return }
        if !isFinal { session.changedEvents += 1 }
        session.pointer = value.location
        session.center = CGPoint(x: session.sourceRect.midX + min(10, max(-10, (value.location.x - session.initialPointer.x) * 0.12)),
                                 y: value.location.y - session.grabOffsetY + BrowserDesign.rowHeight / 2)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { dragSession = session }
        // A batch of drag events can finish before SwiftUI updates the timer
        // representable. Give edge entry an immediate, time-limited response.
        autoScrollTick(viewportHeight: viewportHeight, tick: 0)
        updateDraftDestination()
    }

    private func updateDraftDestination() {
        guard let session = dragSession, !session.isSettling else { return }
        let proposed = Int(((session.center.y + scrollMetrics.offsetY - SidebarTabDragGeometry.contentInset
                             - BrowserDesign.rowHeight / 2) / SidebarTabDragGeometry.stride).rounded())
        let order = TabReordering.moving(session.id, in: draftOrder, pinnedIDs: session.pinnedIDs, to: proposed)
        guard order != draftOrder else { return }
        withAnimation(reduceMotion ? nil : BrowserMotion.spring) { draftOrder = order }
    }

    private func endDrag(_ id: UUID, value: DragGesture.Value, viewport: CGSize) {
        SidebarDragDiagnostics.log("drag.end pointerY=\(value.location.y) viewport=\(viewport.height) offset=\(scrollMetrics.offsetY) blocked=\(blockedGestureID == id) changedEvents=\(dragSession?.changedEvents ?? 0) elapsedMs=\(dragSession.map { Int((ProcessInfo.processInfo.systemUptime - $0.startedAt) * 1000) } ?? 0)")
        if blockedGestureID == id {
            blockedGestureID = nil
            return
        }
        guard let session = dragSession, session.id == id, !session.isSettling else { return }
        let bounds = CGRect(origin: .zero, size: viewport).insetBy(dx: -24, dy: -40)
        guard bounds.contains(value.location), model.tabs.map(\.id) == session.originalOrder,
              pinnedIDs == session.pinnedIDs else {
            cancelDrag()
            return
        }
        // Mouse-up can contain a newer position than the last drag event.
        updateDrag(id, value: value, viewportHeight: viewport.height, isFinal: true)
        guard let destination = draftOrder.firstIndex(of: id) else {
            cancelDrag()
            return
        }
        settleDrag(at: destination, commit: true)
    }

    private func cancelDrag() {
        guard let session = dragSession, !session.isSettling else { return }
        blockedGestureID = session.id
        guard let originalIndex = model.tabs.firstIndex(where: { $0.id == session.id }) else {
            clearDrag(keepBlockedGesture: true)
            return
        }
        settleDrag(at: originalIndex, commit: false)
    }

    private func settleDrag(at destination: Int, commit: Bool) {
        guard var session = dragSession, !session.isSettling else { return }
        let token = session.token
        session.isSettling = true
        session.center = CGPoint(x: session.sourceRect.midX,
                                 y: SidebarTabDragGeometry.contentInset + CGFloat(destination) * SidebarTabDragGeometry.stride
                                    + BrowserDesign.rowHeight / 2 - scrollMetrics.offsetY)
        NSCursor.arrow.set()
        withAnimation(reduceMotion ? nil : BrowserMotion.spring, completionCriteria: .logicallyComplete) {
            dragSession = session
            if commit { model.moveTab(session.id, to: destination) }
            else { draftOrder = model.tabs.map(\.id) }
        } completion: {
            guard dragSession?.token == token else { return }
            clearDrag(keepBlockedGesture: true)
        }
    }

    private func clearDrag(keepBlockedGesture: Bool = false) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragSession = nil
            draftOrder = []
            lastEdgeScrollUptime = 0
            if !keepBlockedGesture { blockedGestureID = nil }
        }
        NSCursor.arrow.set()
    }

    private func gestureStopped(_ id: UUID) {
        if dragSession?.id == id, dragSession?.isSettling == false { cancelDrag() }
        if blockedGestureID == id { blockedGestureID = nil }
    }

    private func cancelIfModelChanged() {
        guard let session = dragSession, !session.isSettling else { return }
        if model.tabs.map(\.id) != session.originalOrder || pinnedIDs != session.pinnedIDs { cancelDrag() }
    }

    private func autoScrollTick(viewportHeight: CGFloat, tick: Int) {
        guard let session = dragSession, !session.isSettling else { return }
        let band: CGFloat = 84
        let velocity: CGFloat
        if session.pointer.y < band {
            velocity = -600 * min(1, max(0, (band - session.pointer.y) / band))
        } else if session.pointer.y > viewportHeight - band {
            velocity = 600 * min(1, max(0, (session.pointer.y - viewportHeight + band) / band))
        } else {
            lastEdgeScrollUptime = 0
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let firstEdgeTick = lastEdgeScrollUptime == 0
        let elapsed = firstEdgeTick ? 1.0 / 60.0 : min(0.05, max(0, now - lastEdgeScrollUptime))
        let delta = velocity * CGFloat(elapsed)
        // Retain an unrendered request when several events share one update,
        // instead of repeatedly starting from stale geometry or overspeeding.
        let base = scrollPosition.isPositionedByUser ? scrollMetrics.offsetY : scrollPosition.y ?? scrollMetrics.offsetY
        let offset = min(scrollMetrics.maximumOffsetY, max(0, base + delta))
        if firstEdgeTick || tick == 1 || (tick > 0 && tick.isMultiple(of: 30)) {
            SidebarDragDiagnostics.log("scroll.request source=\(tick == 0 ? "gesture" : "timer") tick=\(tick) pointerY=\(session.pointer.y) viewport=\(viewportHeight) delta=\(delta) offset=\(scrollMetrics.offsetY) max=\(scrollMetrics.maximumOffsetY) requested=\(offset)")
        }
        if abs(offset - base) > 0.1 {
            lastEdgeScrollUptime = now
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { scrollPosition.scrollTo(y: offset) }
        } else if offset == base && (offset == 0 || offset == scrollMetrics.maximumOffsetY) {
            lastEdgeScrollUptime = now
        }
    }

    private func canMove(_ id: UUID, by step: Int) -> Bool {
        let order = model.tabs.map(\.id)
        guard let index = order.firstIndex(of: id),
              let destination = TabReordering.destinationIndex(for: id, in: order, pinnedIDs: pinnedIDs, proposedIndex: index + step) else { return false }
        return destination != index
    }

    private func moveAccessibly(_ id: UUID, by step: Int) {
        guard let index = model.tabs.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(reduceMotion ? nil : BrowserMotion.spring) { model.moveTab(id, to: index + step) }
    }
}

private struct BrowserTabRow: View {
    let tab: BrowserTab
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    let copy: () -> Void
    let newTab: () -> Void
    let duplicate: () -> Void
    let togglePin: () -> Void
    let editAddress: () -> Void
    let dragChanged: (DragGesture.Value) -> Void
    let dragEnded: (DragGesture.Value) -> Void
    let dragCancelled: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 1) {
            selectionButton
            if hovered {
                HStack(spacing: 2) {
                    if tab.url != nil { miniButton("link", label: L10n.string("Copy Link"), action: copy) }
                    miniButton("xmark", label: L10n.string("Close Tab"), action: close)
                }
                .padding(.trailing, 7)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            }
        }
        .foregroundStyle(colorScheme == .dark ? Color.primary : Color(white: 0.176))
        .frame(height: BrowserDesign.rowHeight)
        .background(Color.white.opacity(colorScheme == .dark ? (hovered ? 0.08 : selected ? 0.14 : 0) : (hovered ? 0.5 : selected ? 1 : 0)), in: Capsule())
        .contentShape(Capsule())
        .onHover { value in withAnimation(reduceMotion ? nil : BrowserMotion.interaction) { hovered = value } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityValue(tab.isPinned ? L10n.string("Pinned") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityActions {
            Button(L10n.string("Open Tab"), action: select)
            Button(L10n.string("New Tab"), action: newTab)
            Button(L10n.string("Duplicate Tab"), action: duplicate)
            Button(L10n.string(tab.isPinned ? "Unpin Tab" : "Pin Tab"), action: togglePin)
            Button(L10n.string("Move Tab Up"), action: moveUp).disabled(!canMoveUp)
            Button(L10n.string("Move Tab Down"), action: moveDown).disabled(!canMoveDown)
            Button(L10n.string("Close Tab"), action: close)
            if tab.url != nil { Button(L10n.string("Copy Link"), action: copy) }
        }
        .help(tab.url?.absoluteString ?? L10n.string("New Tab"))
        .contextMenu {
            Button(L10n.string("Open Address…"), systemImage: "magnifyingglass") { select(); editAddress() }
            Button(L10n.string("Copy Link"), systemImage: "link", action: copy).disabled(tab.url == nil)
            Divider()
            Button(L10n.string("New Tab"), systemImage: "plus", action: newTab)
            Button(L10n.string("Duplicate Tab"), systemImage: "plus.square.on.square", action: duplicate)
            Button(L10n.string(tab.isPinned ? "Unpin Tab" : "Pin Tab"), systemImage: tab.isPinned ? "pin.slash" : "pin", action: togglePin)
            Divider()
            Button(L10n.string("Close Tab"), systemImage: "xmark", action: close)
        }
    }

    private var selectionButton: some View {
        Button(action: select) {
            HStack(spacing: 7) {
                SidebarTabFavicon(tab: tab)
                Text(tab.displayTitle)
                    .font(.system(size: 12, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 16)
                if tab.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 10, height: 12)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, hovered ? 0 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: BrowserDesign.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SidebarTabDragGesture(onChanged: dragChanged, onEnded: dragEnded, onCancelled: dragCancelled))
        .simultaneousGesture(TapGesture(count: 2).onEnded { select(); editAddress() })
        .accessibilityLabel(tab.displayTitle)
    }

    private func miniButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(colorScheme == .dark ? Color.primary : Color.black)
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
            .buttonStyle(RowActionStyle())
            .accessibilityLabel(label)
            .help(label)
    }
}

struct GlassSymbolButton: View {
    let symbol: String
    let label: String
    let help: String
    let action: () -> Void
    init(_ symbol: String, label: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.help = help; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: BrowserDesign.buttonSize, height: BrowserDesign.buttonSize)
                .contentShape(Circle())
        }
        .buttonStyle(SpringGlassStyle())
        .accessibilityLabel(label)
        .help(help)
    }
}

private struct SpringGlassStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .glassEffect(.regular.interactive(enabled), in: Circle())
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(BrowserMotion.interaction, value: configuration.isPressed)
    }
}

private struct RowActionStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var buttonHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background((colorScheme == .dark ? Color.white : Color.black).opacity(configuration.isPressed ? 0.1 : buttonHovered ? 0.06 : 0), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .onHover { buttonHovered = $0 }
            .animation(reduceMotion ? nil : BrowserMotion.interaction, value: configuration.isPressed)
            .animation(reduceMotion ? nil : BrowserMotion.interaction, value: buttonHovered)
    }
}

private struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        // The window owns the appearance preference, including following macOS.
        view.appearance = nil
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.appearance = nil
    }
}

extension View {
    /// Moves the window from empty space. Views layered above keep their own gestures.
    func windowDragBackground() -> some View {
        background {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
        }
    }
}

private struct WindowDragArea: NSViewRepresentable {
    class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil) } else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

private struct PageErrorView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
            Text(L10n.string("Unable to Open This Page")).font(.system(size: 19, weight: .medium))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
            Button(L10n.string("Reload"), systemImage: "arrow.clockwise", action: retry).buttonStyle(.glass).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
