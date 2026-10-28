import AppKit
import SwiftUI

// Measurements come from Pico / Nous Browser, 373:417.
enum BrowserDesign {
    // Pico 391:485 — the icon rail keeps the same 36 pt rows and 12 pt insets.
    static let compactSidebarWidth: CGFloat = 60
    static let inset: CGFloat = 12
    static let buttonSize: CGFloat = 36
    static let bottomButtonSize: CGFloat = 32
    static let bottomButtonSpacing: CGFloat = 8
    static let topContentInset: CGFloat = inset * 2 + buttonSize
    static let bottomContentInset: CGFloat = inset * 2 + bottomButtonSize
    static let lightWindowBacking = Color(white: 250.0 / 255.0)
    static let darkWindowBacking = Color(white: 0.12)
    static let windowBackingOpacity = 0.90
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
    @State private var tabTooltip = SidebarTabTooltipState()
    @State private var updateTooltipVisible = false

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = model.isSidebarCompact ? BrowserDesign.compactSidebarWidth
                : CGFloat(SidebarSizing.effectiveWidth(preferred: model.sidebarWidth, windowWidth: geometry.size.width))
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
                    .overlay((colorScheme == .dark ? BrowserDesign.darkWindowBacking : BrowserDesign.lightWindowBacking)
                        .opacity(BrowserDesign.windowBackingOpacity))

                BrowserSidebar(controller: controller, tooltip: tabTooltip, updateHover: { updateTooltipVisible = $0 })
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

                if model.isSidebarVisible && !model.isSidebarCompact {
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

                if let tip = tabTooltip.presented, model.isSidebarVisible, model.isSidebarCompact,
                   !controller.isAddressPresented {
                    SidebarTabTooltip(title: tip.title)
                        .frame(maxWidth: min(360, geometry.size.width - 76), alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(x: 52, y: max(14, min(geometry.size.height - 14, tip.centerY)) - geometry.size.height / 2)
                        .transition(.scale(scale: 0.94, anchor: .leading).combined(with: .opacity))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .zIndex(1.5)
                }

                if updateTooltipVisible, model.isSidebarVisible, BrowserUpdater.shared.showsButton,
                   !controller.isAddressPresented {
                    SidebarTabTooltip(title: BrowserUpdater.shared.status)
                        .fixedSize()
                        .position(x: model.isSidebarCompact ? 52 + 64 : sidebarWidth - 68,
                                  y: geometry.size.height - (model.isSidebarCompact ? 148 : 64))
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .zIndex(1.6)
                }

                if controller.isAddressPresented {
                    Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08)
                        .contentShape(Rectangle())
                        .onTapGesture { controller.dismissAddress() }
                        .transition(.opacity)
                    AddressPalette(controller: controller, maximumSuggestionsHeight:
                        max(90, geometry.size.height - min(92, geometry.size.height * 0.13) - 113))
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
            .animation(reduceMotion ? nil : BrowserMotion.spring, value: model.isSidebarCompact)
            .animation(reduceMotion ? nil : BrowserMotion.spring, value: BrowserUpdater.shared.showsButton)
            .animation(reduceMotion ? nil : BrowserMotion.spring, value: controller.isAddressPresented)
            .animation(reduceMotion ? nil : BrowserMotion.tabSwitch, value: model.selectedTabID)
        }
        .ignoresSafeArea()
        .scrollIndicators(.hidden)
        .onExitCommand {
            if controller.isAddressPresented { controller.dismissAddress() }
            else if controller.find.isPresented { controller.find.dismiss() }
            else if model.selectedTab?.isLoading == true { model.stopLoading() }
        }
        .onChange(of: model.selectedTabID) { controller.find.pageDidChange() }
        .onChange(of: model.isSidebarVisible) { tabTooltip.dismiss(); updateTooltipVisible = false }
        .onChange(of: model.isSidebarCompact) { tabTooltip.dismiss(); updateTooltipVisible = false }
        .onChange(of: model.selectedTabID) { tabTooltip.dismiss() }
        .onChange(of: controller.isAddressPresented) { tabTooltip.dismiss() }
        .onChange(of: model.selectedTab?.url) { controller.find.pageDidChange() }
        .onChange(of: model.selectedTab?.isLoading) { controller.find.pageDidChange() }
        .sheet(isPresented: Binding(get: { controller.passwords.isPresented },
                                    set: { controller.passwords.isPresented = $0 })) {
            BrowserPasswordsSheet(controller: controller.passwords)
        }
    }

    @ViewBuilder private var page: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .textBackgroundColor)
            WebViewDeck(tabs: model.tabs, selectedID: model.selectedTab?.hasWebContent == true ? model.selectedTabID : nil, owner: model)
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
        .overlay(alignment: .topTrailing) {
            if controller.find.isPresented {
                BrowserPageFindBar(find: controller.find)
                    .padding(16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : BrowserMotion.spring, value: controller.find.isPresented)
        .animation(reduceMotion ? nil : BrowserMotion.spring, value: controller.passwords.canFill)
    }
}

private struct BrowserSidebar: View {
    let controller: BrowserController
    let tooltip: SidebarTabTooltipState
    var updateHover: (Bool) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var model: BrowserModel { controller.model }
    @State private var draftOrder: [UUID] = []
    @State private var dragSession: SidebarTabDragSession?
    @State private var blockedGestureID: UUID?
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var scrollPosition = ScrollPosition(y: 0)
    @State private var scrollMetrics = SidebarScrollMetrics()
    @State private var lastEdgeScrollUptime: TimeInterval = 0
    @State private var dragWindow = SidebarDragWindowReference()

    private var incomingIndex: Int? { controller.tabDragCoordinator?.insertionIndex(in: controller) }

    private var insertionGap: some View {
        Capsule()
            .fill(Color.primary.opacity(0.045))
            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1) }
            .frame(height: BrowserDesign.rowHeight)
            .accessibilityHidden(true)
    }

    private func registerDragEndpoint(_ viewport: CGSize) {
        controller.tabDragCoordinator?.register(controller, reference: dragWindow, viewport: viewport, metrics: scrollMetrics)
    }

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
                        ForEach(Array(orderedTabs.enumerated()), id: \.element.id) { index, tab in
                            if incomingIndex == index { insertionGap }
                            BrowserTabRow(tab: tab, selected: model.selectedTabID == tab.id, isCompact: model.isSidebarCompact,
                                          select: { withAnimation(reduceMotion ? nil : BrowserMotion.tabSwitch) { model.selectTab(tab.id) } },
                                          close: { withAnimation(reduceMotion ? nil : BrowserMotion.spring) { model.closeTab(tab.id) } },
                                          copy: { controller.copyURL(tab, showsToast: false) },
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
                                          canMoveDown: canMove(tab.id, by: 1),
                                          hoverChanged: { hovering in
                                              if hovering, model.isSidebarCompact, model.isSidebarVisible,
                                                 dragSession == nil, controller.tabDragCoordinator?.tabID == nil,
                                                 !controller.isAddressPresented, let frame = rowFrames[tab.id] {
                                                  tooltip.hover(tabID: tab.id, title: tab.displayTitle, centerY: frame.midY)
                                              } else { tooltip.leave(tabID: tab.id) }
                                          })
                            .background {
                                GeometryReader { rowGeometry in
                                    Color.clear.preference(key: SidebarTabFramePreference.self,
                                                           value: [tab.id: rowGeometry.frame(in: .named(SidebarTabDragGeometry.coordinateSpace))])
                                }
                            }
                            .opacity((controller.tabDragCoordinator?.hides(tab.id) ?? (dragSession?.id == tab.id)) ? 0 : 1)
                            .transition(.asymmetric(insertion: .identity, removal: .scale(scale: 0.92).combined(with: .opacity)))
                        }
                        if incomingIndex == orderedTabs.count { insertionGap }
                    }
                    .padding(.horizontal, BrowserDesign.inset)
                    .padding(.top, SidebarTabDragGeometry.topInset(isCompact: model.isSidebarCompact))
                    .padding(.bottom, SidebarTabDragGeometry.bottomInset(isCompact: model.isSidebarCompact) + (model.isSidebarCompact && BrowserUpdater.shared.showsButton ? 40 : 0))
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
                    if previous.offsetY != metrics.offsetY { tooltip.dismiss() }
                    registerDragEndpoint(geometry.size)
                    updateDraftDestination()
                }
                .onPreferenceChange(SidebarTabFramePreference.self) { rowFrames = $0 }
                .scrollIndicators(.hidden)
                .clipped()
                .animation(reduceMotion ? nil : BrowserMotion.spring, value: model.tabs.map(\.id))
                .animation(reduceMotion ? nil : BrowserMotion.spring, value: draftOrder)
                .animation(reduceMotion ? nil : BrowserMotion.spring, value: incomingIndex)

                VStack(spacing: 0) {
                    SidebarEdgeGlass(edge: .top,
                                     buttonCenters: model.isSidebarCompact ? [30] : [BrowserDesign.inset + BrowserDesign.buttonSize / 2,
                                                     geometry.size.width - BrowserDesign.inset - BrowserDesign.buttonSize / 2],
                                     height: model.isSidebarCompact ? 132 : 88,
                                     controlCenterFromEdge: model.isSidebarCompact ? 52 : BrowserDesign.inset + BrowserDesign.buttonSize / 2)
                    Spacer(minLength: 0)
                    SidebarEdgeGlass(edge: .bottom,
                                     buttonCenters: model.isSidebarCompact ? [30] : [BrowserDesign.inset + BrowserDesign.bottomButtonSize / 2,
                                                     BrowserDesign.inset + BrowserDesign.bottomButtonSize * 1.5 + BrowserDesign.bottomButtonSpacing,
                                                     geometry.size.width - BrowserDesign.inset - BrowserDesign.bottomButtonSize / 2],
                                     height: model.isSidebarCompact ? (BrowserUpdater.shared.showsButton ? 208 : 168) : 88,
                                     controlCenterFromEdge: model.isSidebarCompact ? 68 : BrowserDesign.inset + BrowserDesign.bottomButtonSize / 2)
                }
                // Continue the glass behind the page's corner cutouts without
                // expanding the sidebar's content or interactive area.
                .frame(width: geometry.size.width + BrowserDesign.pageRadius * 2)
                .frame(width: geometry.size.width, alignment: .leading)
                .allowsHitTesting(false)

                if controller.tabDragCoordinator == nil, let session = dragSession, let tab = model.tabs.first(where: { $0.id == session.id }) {
                    SidebarFloatingTab(tab: tab, isSettling: session.isSettling, isCompact: model.isSidebarCompact)
                        .frame(width: max(0, geometry.size.width - BrowserDesign.inset * 2))
                        .position(session.center)
                        .transaction { if !session.isSettling { $0.animation = nil } }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                sidebarControls(in: geometry.size)

                // Keep a clear drag target without blocking rows or the wheel
                // in the transparent gaps between the floating controls.
                WindowDragArea()
                    .frame(height: BrowserDesign.inset)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .coordinateSpace(name: SidebarTabDragGeometry.coordinateSpace)
            .background {
                ZStack {
                    SidebarDragCancellationMonitor(isEnabled: dragSession != nil || blockedGestureID != nil,
                                                   canCancel: dragSession?.isSettling == false,
                                                   onCancel: { cancelDrag() },
                                                   windowReference: dragWindow,
                                                   onPointerRelease: pointerReleased,
                                                   onPointerPress: {
                                                       if dragSession?.isSettling == false { cancelDrag() }
                                                       blockedGestureID = nil
                                                   })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    SidebarTooltipDismissalMonitor(isEnabled: tooltip.isTracking, dismiss: tooltip.dismiss)
                        .frame(width: 0, height: 0)
                    SidebarEdgeAutoScrollDriver(isActive: dragSession?.isSettling == false || incomingIndex != nil,
                                                onTick: {
                                                    dragTick(viewportHeight: geometry.size.height, tick: $0)
                                                    incomingAutoScrollTick(viewportHeight: geometry.size.height)
                                                })
                        .frame(width: 0, height: 0)
                }
                .allowsHitTesting(false)
            }
            .onChange(of: model.tabs.map(\.id)) { _, _ in cancelIfModelChanged(); tooltip.dismiss() }
            .onChange(of: pinnedIDs) { _, _ in cancelIfModelChanged() }
            .onChange(of: model.isSidebarVisible) { _, visible in if !visible { cancelDrag() }; tooltip.dismiss() }
            .onChange(of: model.isSidebarCompact) { _, _ in cancelDrag(); tooltip.dismiss() }
            .onChange(of: controller.tabDragCoordinator?.tabID) { tooltip.dismiss() }
            .onChange(of: controller.isAddressPresented) { _, presented in if presented { cancelDrag() } }
            .onChange(of: geometry.size) { _, size in cancelDrag(); tooltip.dismiss(); registerDragEndpoint(size) }
            .onAppear { registerDragEndpoint(geometry.size) }
            .onDisappear { clearDrag(); tooltip.dismiss(); controller.tabDragCoordinator?.unregister(controller) }
        }
        .contextMenu {
            Button(L10n.string(model.isSidebarCompact ? "Expand Sidebar" : "Collapse Sidebar"), systemImage: "sidebar.left") {
                model.toggleSidebar()
            }
            Button(L10n.string("Hide Sidebar"), systemImage: "rectangle") { model.toggleSidebarHidden() }
            Divider()
            Button(L10n.string("Open Address…"), systemImage: "magnifyingglass", action: controller.showAddress)
            Button(L10n.string("New Tab"), systemImage: "plus", action: controller.newTab)
            Button(L10n.string("New Window"), systemImage: "macwindow.badge.plus", action: controller.newWindow)
            Divider()
            Button(L10n.string("Minimize Window"), systemImage: "minus") { NSApp.keyWindow?.miniaturize(nil) }
            Button(L10n.string("Enter Full Screen"), systemImage: "arrow.up.left.and.arrow.down.right") { NSApp.keyWindow?.toggleFullScreen(nil) }
            Button(L10n.string("Close Window"), systemImage: "xmark.rectangle", action: controller.closeWindow)
        }
    }

    /// Keep the same buttons alive while their centers spring between the two layouts.
    private func sidebarControls(in size: CGSize) -> some View {
        let compact = model.isSidebarCompact
        let topLabel = L10n.string(compact ? "Expand Sidebar" : "Collapse Sidebar")
        return ZStack(alignment: .topLeading) {
            if !compact {
                WindowDragArea()
                    .frame(width: max(0, size.width - 120), height: BrowserDesign.buttonSize)
                    .position(x: size.width / 2, y: 30)
            }
            GlassSymbolButton("sidebar.left", label: topLabel, help: topLabel + "  ⌘/") {
                model.toggleSidebar()
            }
            .position(x: 30, y: 30)
            GlassSymbolButton("plus", label: L10n.string("New Tab"), help: L10n.string("New Tab") + "  ⌘T", action: controller.newTab)
                .position(x: compact ? 30 : size.width - 30, y: compact ? 74 : 30)
            GlassSymbolButton("chevron.left", label: L10n.string("Back"), help: L10n.string("Back") + "  ⌘← / ⌘[",
                              size: BrowserDesign.bottomButtonSize, symbolSize: 10, symbolWeight: .medium) { model.goBack() }
                .disabled(model.selectedTab?.canGoBack != true)
                .position(x: compact ? 30 : 28, y: size.height - 28)
            GlassSymbolButton("chevron.right", label: L10n.string("Forward"), help: L10n.string("Forward") + "  ⌘→ / ⌘]",
                              size: BrowserDesign.bottomButtonSize, symbolSize: 10, symbolWeight: .medium) { model.goForward() }
                .disabled(model.selectedTab?.canGoForward != true)
                .position(x: compact ? 30 : 68, y: size.height - (compact ? 68 : 28))
            if BrowserUpdater.shared.showsButton {
                BrowserUpdateButton(updater: .shared, hover: updateHover)
                    .position(x: compact ? 30 : size.width - 68, y: size.height - (compact ? 148 : 28))
                    .transition(.scale(scale: 0.75).combined(with: .opacity))
            }
            GlassSymbolButton(model.selectedTab?.isLoading == true ? "xmark" : "arrow.trianglehead.clockwise.rotate.90",
                              label: model.selectedTab?.isLoading == true ? L10n.string("Stop Loading") : L10n.string("Reload"),
                              help: model.selectedTab?.isLoading == true ? L10n.string("Stop Loading") : L10n.string("Reload") + "  ⌘R",
                              size: BrowserDesign.bottomButtonSize, symbolSize: 10, symbolWeight: .medium) {
                if model.selectedTab?.isLoading == true { model.stopLoading() } else { model.reload() }
            }
            .position(x: compact ? 30 : size.width - 28, y: size.height - (compact ? 108 : 28))
        }
        .frame(width: size.width, height: size.height)
    }

    private func updateDrag(_ id: UUID, value: DragGesture.Value, viewportHeight: CGFloat, isFinal: Bool = false) {
        guard blockedGestureID != id else { return }
        tooltip.dismiss()
        if dragSession == nil {
            guard let rect = rowFrames[id], model.tabs.contains(where: { $0.id == id }) else { return }
            let order = model.tabs.map(\.id)
            lastEdgeScrollUptime = 0
            draftOrder = order
            dragWindow.lastDragScreenPoint = dragWindow.screenPoint(forSidebarPoint: value.location)
            dragSession = SidebarTabDragSession(id: id, originalOrder: order, pinnedIDs: pinnedIDs,
                                                sourceRect: rect, grabOffsetY: value.startLocation.y - rect.minY,
                                                initialPointer: value.startLocation, pointer: value.location,
                                                center: CGPoint(x: rect.midX, y: rect.midY))
            SidebarDragDiagnostics.log("drag.begin rows=\(order.count) startY=\(value.startLocation.y) rowY=\(rect.minY) offset=\(scrollMetrics.offsetY) max=\(scrollMetrics.maximumOffsetY)")
            if let tab = model.tabs.first(where: { $0.id == id }),
               let point = dragWindow.screenPoint(forSidebarPoint: value.location) {
                controller.tabDragCoordinator?.begin(tab: tab, source: controller, at: point, rowSize: rect.size,
                    grabOffset: CGPoint(x: value.startLocation.x - rect.minX, y: value.startLocation.y - rect.minY))
            }
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
        if let point = dragWindow.screenPoint(forSidebarPoint: value.location) { controller.tabDragCoordinator?.update(at: point) }
        // A batch of drag events can finish before SwiftUI updates the timer
        // representable. Give edge entry an immediate, time-limited response.
        if let point = dragWindow.screenPoint(forSidebarPoint: value.location), !isOutsideSourceWindow(point) {
            autoScrollTick(viewportHeight: viewportHeight, tick: 0)
        }
        updateDraftDestination()
    }

    private func updateDraftDestination() {
        guard let session = dragSession, !session.isSettling else { return }
        let proposed = SidebarTabDragGeometry.proposedIndex(forRowTop: session.center.y - BrowserDesign.rowHeight / 2,
                                                            scrollOffset: scrollMetrics.offsetY, isCompact: model.isSidebarCompact)
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
        // The final gesture event is authoritative. Global mouse state may lag
        // native tracking events (including accessibility-driven input).
        if let point = dragWindow.screenPoint(forSidebarPoint: value.location), finishWindowDrop(at: point) { return }
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
        let rowFrame = SidebarTabDragGeometry.rowFrame(at: destination,
            sidebarWidth: session.sourceRect.width + BrowserDesign.inset * 2, scrollOffset: scrollMetrics.offsetY, isCompact: model.isSidebarCompact)
        session.center = CGPoint(x: rowFrame.midX, y: rowFrame.midY)
        NSCursor.arrow.set()
        controller.tabDragCoordinator?.completeTransfer(to: controller, index: destination)
        withAnimation(reduceMotion ? nil : BrowserMotion.spring, completionCriteria: .logicallyComplete) {
            dragSession = session
            if commit { model.moveTab(session.id, to: destination) }
            else { draftOrder = model.tabs.map(\.id) }
        } completion: {
            guard dragSession?.token == token else { return }
            clearDrag(keepBlockedGesture: true)
        }
    }

    private func clearDrag(keepBlockedGesture: Bool = false, keepingFloatingImage: Bool = false) {
        if !keepingFloatingImage, let coordinator = controller.tabDragCoordinator,
           coordinator.sourceID == ObjectIdentifier(controller), !coordinator.isSettling { coordinator.cancel() }
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
        if dragSession?.id == id, dragSession?.isSettling == false {
            let point = dragWindow.lastDragScreenPoint ?? NSEvent.mouseLocation
            if NSEvent.pressedMouseButtons & 1 == 0 {
                if finishWindowDrop(at: point) { return }
                cancelDrag()
            } else if !isOutsideSourceWindow(point) {
                cancelDrag()
            } else {
                dragSession?.awaitsExternalRelease = true
            }
            // A tracking handoff outside the window can end SwiftUI's gesture
            // while the mouse remains down. The common-mode driver waits for up.
        }
        if blockedGestureID == id { blockedGestureID = nil }
    }

    private func isOutsideSourceWindow(_ point: NSPoint) -> Bool {
        guard let window = dragWindow.window as? BrowserWindow,
              window.browserController === controller else { return false }
        return SidebarTabDragGeometry.isOutsideWindow(point, frame: window.frame)
    }

    @discardableResult
    private func finishWindowDrop(at point: NSPoint) -> Bool {
        guard let session = dragSession, !session.isSettling,
              blockedGestureID != session.id,
              model.tabs.map(\.id) == session.originalOrder, pinnedIDs == session.pinnedIDs else { return false }
        let coordinator = controller.tabDragCoordinator
        let destination = coordinator?.destination(at: point)
        guard destination != nil || isOutsideSourceWindow(point) else { return false }
        let id = session.id
        // Consume the session before activating or closing windows. Late up,
        // gesture cancellation and resign-key callbacks cannot transfer twice.
        coordinator?.prepareForDrop()
        clearDrag(keepingFloatingImage: true)
        let moved: Bool
        if let destination {
            moved = controller.moveTab(id, to: destination.controller, at: destination.index)
        } else {
            moved = controller.moveTabToNewWindow(id, at: point)
        }
        if !moved { coordinator?.cancel() }
        return true
    }

    private func pointerReleased(_ point: NSPoint) {
        if finishWindowDrop(at: point) { return }
        guard let session = dragSession else { return }
        let token = session.token
        Task { @MainActor in
            await Task.yield()
            guard dragSession?.token == token else { return }
            if dragSession?.isSettling == false { cancelDrag() }
            if blockedGestureID == session.id { blockedGestureID = nil }
        }
    }

    private func dragTick(viewportHeight: CGFloat, tick: Int) {
        guard dragSession?.isSettling == false else { return }
        let point = dragSession.flatMap { dragWindow.screenPoint(forSidebarPoint: $0.pointer) }
            ?? NSEvent.mouseLocation
        if dragSession?.awaitsExternalRelease == true, NSEvent.pressedMouseButtons & 1 == 0,
           finishWindowDrop(at: NSEvent.mouseLocation) { return }
        guard !isOutsideSourceWindow(point) else { lastEdgeScrollUptime = 0; return }
        autoScrollTick(viewportHeight: viewportHeight, tick: tick)
    }

    private func incomingAutoScrollTick(viewportHeight: CGFloat) {
        guard let pointer = controller.tabDragCoordinator?.incomingPointer(in: controller) else { return }
        let topBand: CGFloat = model.isSidebarCompact ? 128 : 84
        let bottomBand: CGFloat = model.isSidebarCompact ? 160 : 84
        let velocity: CGFloat
        if pointer.y < topBand { velocity = -600 * min(1, max(0, (topBand - pointer.y) / topBand)) }
        else if pointer.y > viewportHeight - bottomBand { velocity = 600 * min(1, max(0, (pointer.y - viewportHeight + bottomBand) / bottomBand)) }
        else { lastEdgeScrollUptime = 0; return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastEdgeScrollUptime == 0 ? 1.0 / 60.0 : min(0.05, max(0, now - lastEdgeScrollUptime))
        lastEdgeScrollUptime = now
        let base = scrollPosition.isPositionedByUser ? scrollMetrics.offsetY : scrollPosition.y ?? scrollMetrics.offsetY
        let offset = min(scrollMetrics.maximumOffsetY, max(0, base + velocity * CGFloat(dt)))
        guard abs(offset - base) > 0.1 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { scrollPosition.scrollTo(y: offset) }
    }

    private func cancelIfModelChanged() {
        guard let session = dragSession, !session.isSettling else { return }
        if model.tabs.map(\.id) != session.originalOrder || pinnedIDs != session.pinnedIDs { cancelDrag() }
    }

    private func autoScrollTick(viewportHeight: CGFloat, tick: Int) {
        guard let session = dragSession, !session.isSettling else { return }
        guard session.pointer.x >= 0, session.pointer.x <= session.sourceRect.maxX + BrowserDesign.inset else {
            lastEdgeScrollUptime = 0
            return
        }
        let topBand: CGFloat = model.isSidebarCompact ? 128 : 84
        let bottomBand: CGFloat = model.isSidebarCompact ? 160 : 84
        let velocity: CGFloat
        if session.pointer.y < topBand {
            velocity = -600 * min(1, max(0, (topBand - session.pointer.y) / topBand))
        } else if session.pointer.y > viewportHeight - bottomBand {
            velocity = 600 * min(1, max(0, (session.pointer.y - viewportHeight + bottomBand) / bottomBand))
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
    let isCompact: Bool
    let select: () -> Void
    let close: () -> Void
    let copy: () -> Bool
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
    let hoverChanged: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false
    @State private var isLinkCopied = false
    @State private var copyFeedbackToken: UUID?
    private var showsActions: Bool { !isCompact && (hovered || isLinkCopied) }

    var body: some View {
        HStack(spacing: 1) {
            selectionButton
            if showsActions {
                HStack(spacing: 2) {
                    if tab.url != nil { copyLinkButton }
                    miniButton("xmark", label: L10n.string("Close Tab"), action: close)
                }
                .padding(.trailing, 7)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            }
        }
        .foregroundStyle(colorScheme == .dark ? Color.primary : Color(white: 0.176))
        .frame(height: BrowserDesign.rowHeight)
        .background(Color.white.opacity(colorScheme == .dark ? (hovered ? 0.08 : selected ? 0.14 : 0) : (hovered ? 0.5 : selected ? 1 : 0)), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder((colorScheme == .dark ? Color.white : Color.black).opacity(selected ? 0.08 : 0), lineWidth: 0.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .animation(reduceMotion ? nil : BrowserMotion.tabSwitch, value: selected)
        }
        .contentShape(Capsule())
        .onHover { value in
            withAnimation(reduceMotion ? nil : BrowserMotion.interaction) { hovered = value }
            hoverChanged(value)
        }
        .task(id: copyFeedbackToken) {
            guard let token = copyFeedbackToken else { return }
            do { try await Task.sleep(for: .seconds(1.2)) }
            catch { return }
            guard !Task.isCancelled, copyFeedbackToken == token else { return }
            withAnimation(reduceMotion ? nil : BrowserMotion.interaction) {
                isLinkCopied = false
                copyFeedbackToken = nil
            }
        }
        .onDisappear {
            hoverChanged(false)
            isLinkCopied = false
            copyFeedbackToken = nil
        }
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
            if tab.url != nil { Button(L10n.string("Copy Link"), action: copyLink) }
        }
        .modifier(SidebarTabHelp(isCompact: isCompact, text: tab.url?.absoluteString ?? L10n.string("New Tab")))
        .contextMenu {
            Button(L10n.string("Open Address…"), systemImage: "magnifyingglass") { select(); editAddress() }
            Button(L10n.string("Copy Link"), systemImage: "link", action: copyLink).disabled(tab.url == nil)
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
                if !isCompact {
                Text(tab.displayTitle)
                    .font(.system(size: 12, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 16)
                if tab.isPinned {
                    Image(systemName: "pin")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 10, height: 12)
                        .accessibilityHidden(true)
                }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, showsActions ? 8 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: BrowserDesign.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SidebarTabDragGesture(onChanged: dragChanged, onEnded: dragEnded, onCancelled: dragCancelled))
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !isCompact { select(); editAddress() } })
        .accessibilityLabel(tab.displayTitle)
    }

    private func copyLink() {
        guard copy() else { return }
        copyFeedbackToken = UUID()
        withAnimation(reduceMotion ? nil : BrowserMotion.interaction) { isLinkCopied = true }
    }

    private var copyLinkButton: some View {
        Button(action: copyLink) {
            ZStack {
                Image(systemName: "link")
                    .scaleEffect(isLinkCopied ? 0.01 : 1)
                    .opacity(isLinkCopied ? 0 : 1)
                Image(systemName: "checkmark")
                    .scaleEffect(isLinkCopied ? 1 : 0.01)
                    .opacity(isLinkCopied ? 1 : 0)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(colorScheme == .dark ? Color.primary : Color.black)
            .frame(width: 20, height: 20)
            .contentShape(Circle())
        }
        .buttonStyle(RowActionStyle())
        .accessibilityLabel(L10n.string("Copy Link"))
        .accessibilityValue(isLinkCopied ? L10n.string("Link Copied") : "")
        .help(L10n.string(isLinkCopied ? "Link Copied" : "Copy Link"))
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
    let size: CGFloat
    let symbolSize: CGFloat
    let symbolWeight: Font.Weight
    let action: () -> Void
    init(_ symbol: String, label: String, help: String,
         size: CGFloat = BrowserDesign.buttonSize, symbolSize: CGFloat = 15, symbolWeight: Font.Weight = .regular,
         action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.help = help; self.action = action
        self.size = size; self.symbolSize = symbolSize; self.symbolWeight = symbolWeight
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: symbolWeight))
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: size, height: size)
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
