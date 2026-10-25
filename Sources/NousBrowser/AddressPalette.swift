import AppKit
import SwiftUI

struct AddressPalette: View {
    @Bindable var controller: BrowserController
    @Environment(\.colorScheme) private var colorScheme
    @State private var highlighted = 0
    private var matchingTabs: [BrowserTab] {
        let text = controller.addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 1, !text.contains("://") else { return [] }
        return Array(controller.model.tabs.filter {
            $0.url != nil && ($0.title.localizedCaseInsensitiveContains(text) || ($0.url?.host?.localizedCaseInsensitiveContains(text) ?? false))
        }.prefix(4))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .regular)).foregroundStyle(.secondary)
                AddressInput(text: $controller.addressText, submit: submitSelection,
                             cancel: controller.dismissAddress,
                             move: { direction in highlighted = min(max(0, highlighted + direction), matchingTabs.count) })
                    .id(controller.addressFocusToken)
                    .frame(height: 26)
                    .onChange(of: controller.addressText) { highlighted = 0 }
            }
            .padding(.horizontal, 22).padding(.vertical, 21)

            Divider().opacity(0.45).padding(.horizontal, 18)

            VStack(spacing: 3) {
                if controller.addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 8) {
                        quickLink("Apple", symbol: "apple.logo", url: "https://www.apple.com")
                        quickLink("Google", symbol: "magnifyingglass", url: "https://www.google.com")
                        quickLink(L10n.string("Wikipedia"), symbol: "book", url: "https://www.wikipedia.org")
                        quickLink("ChatGPT", symbol: "bubble.left.and.bubble.right", url: "https://chatgpt.com")
                    }
                    .padding(.vertical, 9)
                } else {
                    paletteRow(symbol: isWebAddress ? "globe" : "magnifyingglass",
                               title: controller.addressText,
                               subtitle: isWebAddress ? L10n.string("Open Website") : L10n.string("Search with Google"),
                               selected: highlighted == 0) { controller.submitAddress() }
                    ForEach(Array(matchingTabs.enumerated()), id: \.element.id) { index, tab in
                        paletteRow(symbol: "rectangle.on.rectangle", title: tab.displayTitle, subtitle: L10n.string("Switch to Open Tab"), selected: highlighted == index + 1) {
                            controller.model.selectTab(tab.id)
                            controller.dismissAddress()
                        }
                    }
                }
            }
            .padding(10)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.14), radius: 35, y: 14)
        .onExitCommand { controller.dismissAddress() }
    }

    private var isWebAddress: Bool {
        let text = controller.addressText
        return !text.contains(" ") && (text.contains(".") || text.contains("://") || text.hasPrefix("localhost"))
    }

    private func submitSelection() {
        if highlighted > 0, matchingTabs.indices.contains(highlighted - 1) {
            controller.model.selectTab(matchingTabs[highlighted - 1].id)
            controller.dismissAddress()
        } else { controller.submitAddress() }
    }

    private func quickLink(_ title: String, symbol: String, url: String) -> some View {
        Button {
            controller.addressText = url
            controller.submitAddress()
        } label: {
            VStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 19, weight: .regular)).frame(height: 24)
                Text(title).font(.system(size: 11))
            }
            .foregroundStyle(.primary.opacity(0.8))
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(PaletteButtonStyle())
    }

    private func paletteRow(symbol: String, title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15)).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "return").font(.system(size: 12)).foregroundStyle(.tertiary) }
            }
            .foregroundStyle(.primary)
            .padding(12)
            .background(.white.opacity(selected ? (colorScheme == .dark ? 0.10 : 0.65) : 0), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(PaletteButtonStyle())
    }
}

private struct PaletteButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(hovered ? (colorScheme == .dark ? 0.065 : 0.035) : 0), in: RoundedRectangle(cornerRadius: 14))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .onHover { hovered = $0 }
            .animation(BrowserMotion.interaction, value: configuration.isPressed)
            .animation(BrowserMotion.interaction, value: hovered)
    }
}

struct NewTabView: View {
    let controller: BrowserController
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "safari").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(.primary.opacity(0.45))
            VStack(spacing: 8) {
                Text("Nous Browser").font(.system(size: 27, weight: .medium)).tracking(-0.7)
                Text(L10n.string("More room for the web.")).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Button(action: controller.showAddress) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                    Text(L10n.string("Search or enter address"))
                    Spacer()
                    Text("⌘L").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: 340)
                .glassEffect(.regular.interactive(), in: Capsule())
            }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .windowDragBackground()
        .background(Color(nsColor: .textBackgroundColor))
    }
}


// Native focus keeps ⌘L reliable even while a webpage owns the first responder.
private struct AddressInput: NSViewRepresentable {
    @Binding var text: String
    let submit: () -> Void
    let cancel: () -> Void
    let move: (Int) -> Void

    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
                self.selectText(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressInput
        init(_ parent: AddressInput) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)): parent.submit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel(); return true
            case #selector(NSResponder.moveDown(_:)): parent.move(1); return true
            case #selector(NSResponder.moveUp(_:)): parent.move(-1); return true
            default: return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.stringValue = text
        field.placeholderString = L10n.string("Search or enter address")
        field.font = .systemFont(ofSize: 18)
        field.textColor = .labelColor
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.setAccessibilityLabel(L10n.string("Search or enter address"))
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.textColor = .labelColor
        if field.stringValue != text { field.stringValue = text }
    }
}
