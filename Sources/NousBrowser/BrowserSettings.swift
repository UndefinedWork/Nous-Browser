import SwiftUI

struct BrowserSettingsView: View {
    let preferences: BrowserPreferences
    let appearance: BrowserAppearanceSettings
    let passwordImporter: BrowserPasswordController
    let automation: BrowserAutomationService

    var body: some View {
        TabView {
            SearchSettingsView(preferences: preferences)
                .tabItem { Label(L10n.string("Search"), systemImage: "magnifyingglass") }
            QuickAccessSettingsView(preferences: preferences)
                .tabItem { Label(L10n.string("Quick Access"), systemImage: "square.grid.2x2") }
            PasswordImportSettingsView(controller: passwordImporter)
                .tabItem { Label(L10n.string("Passwords"), systemImage: "key") }
            AppearanceSettingsView(appearance: appearance)
                .tabItem { Label(L10n.string("Appearance"), systemImage: "circle.lefthalf.filled") }
            BrowserAutomationSettingsView(service: automation)
                .tabItem { Label(L10n.string("AI Agents (MCP)"), systemImage: "point.3.connected.trianglepath.dotted") }
        }
        .padding(20)
        .frame(width: 580, height: 430)
        .onDisappear { passwordImporter.dismiss() }
    }
}

private struct SearchSettingsView: View {
    @Bindable var preferences: BrowserPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("Default Search Engine")).font(.title2.weight(.semibold))
            Text(L10n.string("Searches from the address bar use this engine."))
                .foregroundStyle(.secondary)
            Picker(L10n.string("Default Search Engine"), selection: Binding(
                get: { preferences.searchEngine }, set: { preferences.selectSearchEngine($0) }
            )) {
                ForEach(BrowserSearchEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .labelsHidden()
            .frame(width: 220, alignment: .leading)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }
}

private struct AppearanceSettingsView: View {
    @Bindable var appearance: BrowserAppearanceSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("Appearance")).font(.title2.weight(.semibold))
            Text(L10n.string("Choose how Nous Browser looks."))
                .foregroundStyle(.secondary)
            Picker(L10n.string("Appearance"), selection: Binding(
                get: { appearance.mode }, set: { appearance.select($0) }
            )) {
                ForEach(BrowserAppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }
}

private struct PasswordImportSettingsView: View {
    @Bindable var controller: BrowserPasswordController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("Password Import")).font(.title2.weight(.semibold))
            Text(L10n.string("Export passwords from Apple Passwords or Chrome, then choose the CSV file here."))
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.string("Passwords stay in your Mac’s keychain. Your Mac verifies you before import and filling."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.string("Import Passwords…"), systemImage: "square.and.arrow.down",
                   action: controller.presentImport)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .sheet(isPresented: Binding(get: { controller.isPresented }, set: { if !$0 { controller.dismiss() } })) {
            BrowserPasswordsSheet(controller: controller)
        }
    }
}

private struct QuickAccessSettingsView: View {
    @Bindable var preferences: BrowserPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editor: QuickLinkEditorItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.string("Quick Access")).font(.title2.weight(.semibold))
                Spacer()
                Button { editor = QuickLinkEditorItem(link: nil) } label: {
                    Label(L10n.string("Add Website"), systemImage: "plus")
                }
            }
            Text(L10n.string("Choose which websites appear when you press ⌘L."))
                .foregroundStyle(.secondary)
            ScrollView {
                if preferences.quickLinks.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.tertiary)
                        Text(L10n.string("No Quick Access Websites")).font(.headline)
                        Text(L10n.string("Add your favorite websites for quick access."))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    VStack(spacing: 1) {
                        ForEach(Array(preferences.quickLinks.enumerated()), id: \.element.id) { index, link in
                            row(link, at: index)
                            if index < preferences.quickLinks.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .scrollIndicators(.hidden)
            HStack {
                Spacer()
                Button(L10n.string("Restore Defaults")) {
                    withAnimation(reduceMotion ? nil : BrowserMotion.spring) {
                        preferences.restoreDefaultQuickLinks()
                    }
                }
            }
        }
        .padding(24)
        .sheet(item: $editor) { item in
            QuickLinkEditor(preferences: preferences, link: item.link)
        }
    }

    private func row(_ link: BrowserQuickLink, at index: Int) -> some View {
        HStack(spacing: 12) {
            QuickLinkIcon(link: link).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.title).font(.body.weight(.medium)).lineLimit(1)
                Text(link.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            rowButton("Move Up", symbol: "chevron.up") { move(link, offset: -1) }
                .disabled(index == 0)
            rowButton("Move Down", symbol: "chevron.down") { move(link, offset: 1) }
                .disabled(index == preferences.quickLinks.count - 1)
            rowButton("Edit Website", symbol: "pencil") { editor = QuickLinkEditorItem(link: link) }
            rowButton("Remove", symbol: "minus.circle") {
                withAnimation(reduceMotion ? nil : BrowserMotion.spring) { preferences.removeQuickLink(id: link.id) }
            }
        }
        .padding(8)
    }

    private func rowButton(_ key: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 26).contentShape(Rectangle())
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
