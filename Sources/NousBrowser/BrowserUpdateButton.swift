import SwiftUI

struct BrowserUpdateButton: View {
    @Bindable var updater: BrowserUpdater
    var hover: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button { updater.installUpdate() } label: {
            ZStack {
                if updater.isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "square.and.arrow.down.badge.checkmark")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(UpdateGlassStyle())
        .accessibilityLabel(updater.status)
        .onHover { isHovered = $0; if !$0 { hover(false) } }
        .task(id: isHovered) {
            guard isHovered else { return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : BrowserMotion.interaction) { hover(true) }
        }
        .onDisappear { hover(false) }
    }
}

private struct UpdateGlassStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .glassEffect(.regular.interactive(), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(reduceMotion ? nil : BrowserMotion.interaction, value: configuration.isPressed)
    }
}
