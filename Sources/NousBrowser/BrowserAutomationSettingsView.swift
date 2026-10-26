import AppKit
import SwiftUI

struct BrowserAutomationSettingsView: View {
    @Bindable var service: BrowserAutomationService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @State private var showsConfiguration = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.string("AI Agents (MCP)")).font(.title2.weight(.semibold))
                Text(L10n.string("Connect trusted agents on this Mac using MCP."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(L10n.string("Allow AI agents to use Nous Browser"), isOn: Binding(
                    get: { service.isEnabled }, set: { service.setEnabled($0) }
                ))
                .toggleStyle(.switch)

                Text(L10n.string("Agents can read and interact with your open webpages, including signed-in sites. Turn this off at any time to stop access."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label(statusTitle, systemImage: statusSymbol)
                    .font(.callout)
                    .foregroundStyle(service.statusMessage != nil ? Color.red : Color.secondary)
                    .accessibilityIdentifier("automationStatus")

                HStack {
                    Button(action: copyConfiguration) {
                        Label(L10n.string(copied ? "Configuration Copied" : "Copy Connection Configuration"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    Spacer(minLength: 0)
                }

                DisclosureGroup(L10n.string("Connection Configuration"), isExpanded: $showsConfiguration) {
                    Text(service.connectionConfig)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.top, 6)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("Recent Activity")).font(.caption.weight(.medium))
                    Text(service.lastActivity ?? L10n.string("No agent activity yet."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .scrollIndicators(.hidden)
        .animation(reduceMotion ? nil : BrowserMotion.spring, value: showsConfiguration)
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
