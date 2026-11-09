import AppKit
import SwiftUI

// Measurements come from Pico / Nous Browser, 373:417.
enum BrowserDesign {
    // Pico 391:485 — the icon rail keeps the same 36 pt rows and 12 pt insets.
    static let compactSidebarWidth: CGFloat = 60
    static let inset: CGFloat = 12
    // Pico 448:1297: 32pt top controls with a 12pt medium glyph.
    static let buttonSize: CGFloat = 32
    static let topSymbolSize: CGFloat = 12
    static let bottomButtonSize: CGFloat = 32
    static let bottomButtonSpacing: CGFloat = 8
    static let topContentInset: CGFloat = inset * 2 + buttonSize
    static let bottomContentInset: CGFloat = inset * 2 + bottomButtonSize
    static let lightWindowBacking = Color(white: 250.0 / 255.0)
    static let darkWindowBacking = Color(white: 0.12)
    static let windowBackingOpacity = 0.90
    static let rowHeight: CGFloat = 36
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

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = model.isSidebarCompact ? BrowserDesign.compactSidebarWidth
                : CGFloat(SidebarSizing.effectiveWidth(preferred: model.sidebarWidth, windowWidth: geometry.size.width))
            let maximumWidth = CGFloat(SidebarSizing.effectiveWidth(preferred: SidebarSizing.maximumWidth, windowWidth: geometry.size.width))
            // Only the root mask clips the window perimeter. A second rounded
            // mask blends the light backing into dark webpage edges.
            let pageShape = UnevenRoundedRectangle(
                topLeadingRadius: model.isSidebarPresented ? BrowserDesign.pageRadius : 0,
                bottomLeadingRadius: model.isSidebarPresented ? BrowserDesign.pageRadius : 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
            ZStack(alignment: .leading) {
                WindowMaterial()
                    .overlay((colorScheme == .dark ? BrowserDesign.darkWindowBacking : BrowserDesign.lightWindowBacking)
                        .opacity(BrowserDesign.windowBackingOpacity))

                BrowserSidebar(controller: controller, tooltip: tabTooltip)
                    .frame(width: sidebarWidth)
                    .offset(x: model.isSidebarPresented ? 0 : -sidebarWidth)
                    .opacity(model.isSidebarPresented ? 1 : 0)
                    .allowsHitTesting(model.isSidebarPresented)
                    .accessibilityHidden(!model.isSidebarPresented)

                page
                    .clipShape(pageShape)
                    .overlay {
                        if model.isSidebarPresented {
                            pageShape
                                .strokeBorder((colorScheme == .dark ? Color.white : Color.black).opacity(0.08), lineWidth: 0.6)
                                .mask(alignment: .leading) {
                                    Rectangle().frame(width: BrowserDesign.pageRadius + 1)
                                }
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.leading, model.isSidebarPresented ? sidebarWidth : 0)

                if model.isSidebarPresented && !model.isSidebarCompact {
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

                if let tip = tabTooltip.presented, model.isSidebarPresented, model.isSidebarCompact,
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
            .clipShape(RoundedRectangle(cornerRadius: model.isPageFullscreen ? 0 : CGFloat(controller.appearance.windowCornerRadius), style: .continuous))
            .animation(reduceMotion || isResizingSidebar ? nil : BrowserMotion.spring, value: sidebarWidth)
            .animation(reduceMotion ? nil : BrowserMotion.spring, value: model.isSidebarVisible)
            .animation(reduceMotion ? nil : BrowserMotion.spring, value: model.isSidebarCompact)
            .animation(reduceMotion ? nil : BrowserMotion.spring, value: controller.isAddressPresented)
            .animation(reduceMotion ? nil : BrowserMotion.tabSwitch, value: model.selectedTabID)
        }
        .ignoresSafeArea()
        .scrollIndicators(.hidden)
        .onExitCommand {
            if controller.isAddressPresented { controller.dismissAddress() }
            else if controller.find.isPresented { controller.find.dismiss() }
            else {
                if model.isPageFullscreen {
                    model.selectedTab?.webView.exitPageFullscreen()
                    return
                }
                if model.selectedTab?.isLoading == true { model.stopLoading() }
            }
        }
        .onChange(of: model.selectedTabID) { controller.find.pageDidChange() }
        .onChange(of: model.isSidebarPresented) { tabTooltip.dismiss() }
        .onChange(of: model.isSidebarCompact) { tabTooltip.dismiss() }
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
                if tab.isLoading && !model.isPageFullscreen {
                    GeometryReader { size in
                        Capsule().fill(.primary.opacity(0.5))
                            .frame(width: max(24, size.size.width * tab.estimatedProgress), height: 2)
                            .animation(BrowserMotion.spring, value: tab.estimatedProgress)
                    }
                    .frame(height: 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            } else if let page = model.selectedTab?.nativePage {
                NativePageView(controller: controller, page: page)
                    .id(page.isLibrary ? NativePage.library(.all) : page)
                    .transition(.opacity)
            } else {
                NewTabView(controller: controller)
            }
            // A narrow, transparent drag target keeps the content-only window movable.
            if !model.isPageFullscreen { WindowDragArea().frame(height: 6) }
        }
        .overlay(alignment: .bottomTrailing) {
            if controller.passwords.canFill && !controller.isAddressPresented && !model.isPageFullscreen {
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

struct BrowserTabRow: View {
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
    var menu: AnyView = AnyView(EmptyView())
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
            Group {
            Button(L10n.string("Open Address…"), systemImage: "magnifyingglass") { select(); editAddress() }
            Button(L10n.string("Copy Link"), systemImage: "link", action: copyLink).disabled(tab.url == nil)
            Divider()
            Button(L10n.string("New Tab"), systemImage: "plus", action: newTab)
            Button(L10n.string("Duplicate Tab"), systemImage: "plus.square.on.square", action: duplicate)
            Button(L10n.string(tab.isPinned ? "Unpin Tab" : "Pin Tab"), systemImage: tab.isPinned ? "pin.slash" : "pin", action: togglePin)
            menu
            Divider()
            Button(L10n.string("Close Tab"), systemImage: "xmark", action: close)
            }
            // macOS 27 hides menu icons unless asked for.
            .labelStyle(.titleAndIcon)
        }
    }

    private var selectionButton: some View {
        Button(action: select) {
            HStack(spacing: 7) {
                SidebarTabFavicon(tab: tab)
                if !isCompact {
                Text(tab.pageTitle.title)
                    .font(.system(size: 12, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 16)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, showsActions ? 8 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: BrowserDesign.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

struct WindowDragArea: NSViewRepresentable {
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
