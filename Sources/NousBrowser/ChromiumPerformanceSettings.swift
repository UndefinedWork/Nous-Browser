import Foundation

/// A deliberately domain-only input. Full existing Chrome URL rules remain
/// untouched; Chromium owns their matching and discard eligibility.
nonisolated enum ChromiumMemorySaverDomain {
    static func normalized(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              !value.contains(where: { "/\\:@?#%*[]".contains($0) }),
              let host = URL(string: "https://" + value)?.host(percentEncoded: false)?.lowercased(),
              !host.isEmpty, host.utf8.count <= 253 else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-".utf8)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { allowed.contains($0) }
        }) else { return nil }
        // Chromium interprets shortened and hexadecimal numeric hosts as IP
        // addresses. Accept only ordinary dotted IPv4, or a DNS domain.
        if let last = labels.last, last.allSatisfy(\.isNumber) || last.hasPrefix("0x") {
            guard labels.count == 4, labels.allSatisfy({ part in
                part.allSatisfy(\.isNumber) && (part.count == 1 || part.first != "0")
                    && Int(part).map { (0...255).contains($0) } == true
            }) else { return nil }
        }
        return host
    }
}

import SwiftUI
import NousCore

/// The native engine owns persistence and eligibility, including its default.
/// A UI choice never unloads a tab directly or sets a separate inactivity timer.
struct ChromiumPerformanceSettingsView: View {
    @State private var mode = -1
    @State private var updateFailed = false
    @State private var sites: [String] = []
    @State private var managedSites: [String] = []
    @State private var sitesAvailable = false
    @State private var canEditSites = false
    @State private var domain = ""
    @State private var siteError: String?

    private let titles = ["Off", "Moderate", "Balanced", "Maximum"]

    var body: some View {
        SettingsForm {
            SettingsRow("Memory Saver") {
                if mode >= 0 {
                    Picker(L10n.string("Memory Saver"), selection: Binding(
                        get: { mode },
                        set: { requested in
                            updateFailed = !NBChromiumRuntime.setMemorySaverMode(requested)
                            mode = NBChromiumRuntime.memorySaverMode()
                        }
                    )) {
                        ForEach(titles.indices, id: \.self) { value in
                            Text(L10n.string(titles[value])).tag(value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                } else {
                    ProgressView().controlSize(.small)
                }
                SettingsNote("Free up memory from inactive tabs. They reload when you return to them.")
                if updateFailed {
                    Text(L10n.string("The setting could not be changed. Try again.")).font(.callout).foregroundStyle(.red)
                }
            }
            SettingsGap()
            SettingsRow("Always active") {
                if sitesAvailable {
                    SettingsListBox(height: 112) {
                        if sites.isEmpty && managedSites.isEmpty {
                            Text(L10n.string("No sites added."))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 44)
                        }
                        ForEach(sites, id: \.self) { rule in siteRow(rule, managed: false) }
                        ForEach(managedSites, id: \.self) { rule in siteRow(rule, managed: true) }
                    }
                    .frame(width: 320)
                    if canEditSites {
                        HStack(spacing: 8) {
                            TextField(L10n.string("Domain name (for example, example.com)"), text: $domain)
                                .onSubmit(addSite)
                            Button(L10n.string("Add"), action: addSite)
                                .disabled(domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .frame(width: 320)
                    }
                    if let siteError {
                        Text(L10n.string(siteError)).font(.callout).foregroundStyle(.red)
                    }
                    SettingsNote("These sites won't be deactivated by Memory Saver.")
                    if canEditSites { SettingsNote("Subdomains are included.") }
                    if !canEditSites || !managedSites.isEmpty { SettingsNote("Managed by your organization.") }
                } else {
                    Text(L10n.string("This setting is unavailable.")).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            mode = NBChromiumRuntime.memorySaverMode()
            reloadSites()
        }
    }

    private func siteRow(_ rule: String, managed: Bool) -> some View {
        HStack {
            Text(verbatim: rule).textSelection(.enabled).lineLimit(1)
            Spacer()
            if managed {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
                    .help(L10n.string("Managed by your organization."))
            } else if canEditSites {
                Button { removeSite(rule) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help(L10n.string("Remove"))
                    .accessibilityLabel(L10n.string("Remove") + " " + rule)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 10) }
    }

    private func reloadSites() {
        do {
            guard NBChromiumRuntime.hasNativeTabLifecycle() else { throw CocoaError(.featureUnsupported) }
            let snapshot = try NBChromiumRuntime.memorySaverSites()
            sites = snapshot["sites"] as? [String] ?? []
            managedSites = snapshot["managedSites"] as? [String] ?? []
            canEditSites = snapshot["canEdit"] as? Bool ?? false
            sitesAvailable = true
        } catch {
            sitesAvailable = false
            canEditSites = false
        }
    }

    private func addSite() {
        guard canEditSites else { return }
        guard let normalized = ChromiumMemorySaverDomain.normalized(domain) else {
            siteError = "Enter a valid domain name."
            return
        }
        guard !sites.contains(normalized), !managedSites.contains(normalized) else {
            siteError = "Already in the list."
            return
        }
        do {
            try NBChromiumRuntime.addMemorySaverSite(normalized)
            domain = ""
            siteError = nil
        } catch { siteError = "The setting could not be changed. Try again." }
        reloadSites()
    }

    private func removeSite(_ rule: String) {
        guard canEditSites else { return }
        do {
            try NBChromiumRuntime.removeMemorySaverSite(rule)
            siteError = nil
        } catch { siteError = "The setting could not be changed. Try again." }
        reloadSites()
    }
}
