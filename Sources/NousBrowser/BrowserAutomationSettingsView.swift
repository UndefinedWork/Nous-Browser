import AppKit
import SwiftUI

struct BrowserAutomationSettingsView: View {
    @Bindable var service: BrowserAutomationService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @State private var showsConfiguration = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        SettingsForm {
            SettingsRow("Access") {
                Toggle(L10n.string("Allow AI agents to use Nous Browser"), isOn: Binding(
                    get: { service.isEnabled }, set: { service.setEnabled($0) }
                ))
                .toggleStyle(.checkbox)
                SettingsNote("Connect trusted agents on this Mac using MCP.")
                SettingsNote("Agents can read and interact with your open webpages, including signed-in sites. Turn this off at any time to stop access.")
            }
            SettingsRow("Status") {
                Label(statusTitle, systemImage: statusSymbol)
                    .foregroundStyle(service.statusMessage != nil ? Color.red : Color.primary)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityIdentifier("automationStatus")
            }
            SettingsGap()
            SettingsRow("Connection") {
                Button(action: copyConfiguration) {
                    Label(L10n.string(copied ? "Configuration Copied" : "Copy Connection Configuration"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                Button {
                    withAnimation(reduceMotion ? nil : BrowserMotion.spring) { showsConfiguration.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(showsConfiguration ? 90 : 0))
                            .frame(width: 10)
                        Text(L10n.string("Connection Configuration"))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityValue(L10n.string(showsConfiguration ? "Expanded" : "Collapsed"))
                if showsConfiguration {
                    Text(service.connectionConfig)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(width: 340, alignment: .leading)
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        }
                        .transition(.opacity)
                }
            }
            SettingsRow("Recent Activity") {
                Text(service.lastActivity ?? L10n.string("No agent activity yet."))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 360, alignment: .leading)
            }
        }
        .animation(reduceMotion ? nil : BrowserMotion.spring, value: copied)
        .onDisappear { copyResetTask?.cancel() }
    }

    private var statusTitle: String {
        if !service.isEnabled { return L10n.string("Access is off") }
        if service.statusMessage != nil { return L10n.string("Could not start. Turn access off and try again.") }
        return L10n.string(service.isRunning ? "Ready for local agents" : "Starting…")
    }

    private var statusSymbol: String {
        if !service.isEnabled { return "pause.circle" }
        if service.statusMessage != nil { return "exclamationmark.circle" }
        return service.isRunning ? "checkmark.circle" : "ellipsis.circle"
    }

    private func copyConfiguration() {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(service.connectionConfig, forType: .string) else { return }
        copyResetTask?.cancel()
        copied = true
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
