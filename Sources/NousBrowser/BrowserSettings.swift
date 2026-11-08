import SwiftUI
import NousCore

enum BrowserSettingsPanes {
    @MainActor
    static func make(preferences: BrowserPreferences, appearance: BrowserAppearanceSettings,
                     passwordImporter: BrowserPasswordController,
                     automation: BrowserAutomationService) -> [SettingsWindowController.Pane] {
        var panes: [SettingsWindowController.Pane] = [
            .init(id: "search", title: L10n.string("Search"), symbol: "magnifyingglass",
                  view: AnyView(SearchSettingsView(preferences: preferences))),
            .init(id: "quickAccess", title: L10n.string("Quick Access"), symbol: "square.grid.2x2",
                  view: AnyView(QuickAccessSettingsView(preferences: preferences))),
            .init(id: "passwords", title: L10n.string("Passwords"), symbol: "key",
                  view: AnyView(PasswordImportSettingsView(controller: passwordImporter))),
            .init(id: "appearance", title: L10n.string("Appearance"), symbol: "paintpalette",
                  view: AnyView(AppearanceSettingsView(appearance: appearance))),
            .init(id: "capture", title: L10n.string("Capture"), symbol: "camera.viewfinder",
                  view: AnyView(CaptureShortcutsSettingsView())),
        ]
        if NBChromiumRuntime.hasNativeTabLifecycle() {
            panes.append(.init(id: "performance", title: L10n.string("Performance"),
                               symbol: "gauge.with.dots.needle.67percent",
                               view: AnyView(ChromiumPerformanceSettingsView())))
        }
        panes.append(.init(id: "agents", title: L10n.string("AI Agents (MCP)"),
                           symbol: "point.3.connected.trianglepath.dotted",
                           view: AnyView(BrowserAutomationSettingsView(service: automation))))
        return panes
    }
}

private struct SearchSettingsView: View {
    @Bindable var preferences: BrowserPreferences

    var body: some View {
        SettingsForm {
            SettingsRow("Search engine") {
                Picker(L10n.string("Search engine"), selection: Binding(
                    get: { preferences.searchEngine }, set: { preferences.selectSearchEngine($0) }
                )) {
                    ForEach(BrowserSearchEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .labelsHidden()
                .fixedSize()
                SettingsNote("Searches from the address bar use this engine.")
            }
        }
    }
}

private struct AppearanceSettingsView: View {
    @Bindable var appearance: BrowserAppearanceSettings

    var body: some View {
        SettingsForm {
            SettingsRow("Appearance") {
                Picker(L10n.string("Appearance"), selection: Binding(
                    get: { appearance.mode }, set: { appearance.select($0) }
                )) {
                    ForEach(BrowserAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }
            SettingsGap()
            SettingsRow("Window buttons") {
                Toggle(L10n.string("Show in the sidebar"), isOn: $appearance.showsWindowButtons)
                    .toggleStyle(.checkbox)
                SettingsNote("Close, minimize and full-screen buttons at the top of the sidebar. They stay hidden while the sidebar is hidden.")
            }
            SettingsGap()
            SettingsRow("Window corner radius") {
                HStack(spacing: 10) {
                    Slider(value: $appearance.windowCornerRadius,
                           in: BrowserAppearanceSettings.cornerRadiusRange, step: 1) {
                        Text(L10n.string("Window corner radius"))
                    } minimumValueLabel: {
                        Image(systemName: "square").imageScale(.small).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    } maximumValueLabel: {
                        Image(systemName: "app").imageScale(.small).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    Text("\(Int(appearance.windowCornerRadius)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                    Button(L10n.string("Default")) {
                        appearance.windowCornerRadius = BrowserAppearanceSettings.defaultCornerRadius
                    }
                    .disabled(appearance.windowCornerRadius == BrowserAppearanceSettings.defaultCornerRadius)
                }
                SettingsNote("How round the corners of browser windows are. Full screen always uses square corners.")
            }
        }
    }
}

private struct PasswordImportSettingsView: View {
    @Bindable var controller: BrowserPasswordController

    var body: some View {
        SettingsForm {
            SettingsRow("Import") {
                Button(L10n.string("Import Passwords…"), action: controller.presentImport)
                SettingsNote("Export passwords from Apple Passwords or Chrome, then choose the CSV file here.")
                SettingsNote("Passwords stay in your Mac’s keychain. Your Mac verifies you before import and filling.")
            }
        }
        .sheet(isPresented: Binding(get: { controller.isPresented }, set: { if !$0 { controller.dismiss() } })) {
            BrowserPasswordsSheet(controller: controller)
        }
        .onDisappear { controller.dismiss() }
    }
}

private struct QuickAccessSettingsView: View {
    @Bindable var preferences: BrowserPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editor: QuickLinkEditorItem?
    @State private var hovered: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Choose which websites appear when you press ⌘L."))
                .foregroundStyle(.secondary)
            SettingsListBox(height: 300) {
                if preferences.quickLinks.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2").font(.title).foregroundStyle(.tertiary)
                        Text(L10n.string("No Quick Access Websites")).font(.headline)
                        Text(L10n.string("Add your favorite websites for quick access."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 90)
                } else {
                    ForEach(Array(preferences.quickLinks.enumerated()), id: \.element.id) { index, link in
                        row(link, at: index)
                        if index < preferences.quickLinks.count - 1 { Divider().padding(.leading, 48) }
                    }
                }
            }
            HStack(spacing: 8) {
                Button { editor = QuickLinkEditorItem(link: nil) } label: {
                    Label(L10n.string("Add Website"), systemImage: "plus")
                }
                Spacer()
                Button(L10n.string("Restore Defaults")) {
                    withAnimation(reduceMotion ? nil : BrowserMotion.spring) {
                        preferences.restoreDefaultQuickLinks()
                    }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 28)
        .frame(width: SettingsMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(item: $editor) { item in
            QuickLinkEditor(preferences: preferences, link: item.link)
        }
    }

    private func row(_ link: BrowserQuickLink, at index: Int) -> some View {
        let isHovered = hovered == link.id
        return HStack(spacing: 12) {
            QuickLinkIcon(link: link).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(link.title).lineLimit(1)
                Text(link.url.absoluteString).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                rowButton("Move Up", symbol: "chevron.up") { move(link, offset: -1) }
                    .disabled(index == 0)
                rowButton("Move Down", symbol: "chevron.down") { move(link, offset: 1) }
                    .disabled(index == preferences.quickLinks.count - 1)
                rowButton("Edit Website", symbol: "pencil") { editor = QuickLinkEditorItem(link: link) }
                rowButton("Remove", symbol: "minus.circle") {
                    withAnimation(reduceMotion ? nil : BrowserMotion.spring) { preferences.removeQuickLink(id: link.id) }
                }
            }
            .opacity(isHovered ? 1 : 0.0001)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(isHovered ? 0.04 : 0))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = link.id } else if hovered == link.id { hovered = nil }
        }
        .onTapGesture(count: 2) { editor = QuickLinkEditorItem(link: link) }
    }

    private func rowButton(_ key: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(L10n.string(key))
        .accessibilityLabel(L10n.string(key))
    }

    private func move(_ link: BrowserQuickLink, offset: Int) {
        withAnimation(reduceMotion ? nil : BrowserMotion.spring) {
            preferences.moveQuickLink(id: link.id, offset: offset)
        }
    }
}

private struct QuickLinkEditorItem: Identifiable {
    let id = UUID()
    let link: BrowserQuickLink?
}

private struct QuickLinkEditor: View {
    let preferences: BrowserPreferences
    let link: BrowserQuickLink?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address: String
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(preferences: BrowserPreferences, link: BrowserQuickLink?) {
        self.preferences = preferences
        self.link = link
        _name = State(initialValue: link?.title ?? "")
        _address = State(initialValue: link?.url.absoluteString ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string(link == nil ? "Add Website" : "Edit Website"))
                .font(.title2.weight(.semibold))
            Form {
                TextField(L10n.string("Name"), text: $name).focused($nameFocused)
                TextField(L10n.string("Website"), text: $address)
                    .autocorrectionDisabled()
            }
            .textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(L10n.string("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.string(link == nil ? "Add" : "Save"), action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { nameFocused = true }
    }

    private func save() {
        do {
            if let link { try preferences.updateQuickLink(id: link.id, title: name, address: address) }
            else { try preferences.addQuickLink(title: name, address: address) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
