import AppKit
import SwiftUI

struct AddressPalette: View {
    @Bindable var controller: BrowserController
    var maximumSuggestionsHeight: CGFloat = 340
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var highlighted = 0
    private var suggestions: [BrowserAddressSuggestion] { controller.addressSuggestions }
    private var showsSuggestions: Bool {
        !controller.addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !controller.preferences.quickLinks.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .regular)).foregroundStyle(.secondary)
                AddressInput(text: $controller.addressText, submit: submitSelection,
                             cancel: controller.dismissAddress,
                             move: { direction in highlighted = min(max(0, highlighted + direction), suggestions.count) })
                    .id(controller.addressFocusToken)
                    .frame(height: 26)
                    .onChange(of: controller.addressText) { highlighted = 0 }
            }
            .padding(.horizontal, 22).padding(.vertical, 21)

            if showsSuggestions {
                Divider().opacity(0.45).padding(.horizontal, 18)

                VStack(spacing: 3) {
                    if controller.addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 4) {
                                ForEach(controller.preferences.quickLinks) { link in quickLink(link) }
                            }
                            .padding(.vertical, 9)
                        }
                        .scrollIndicators(.hidden)
                        .frame(height: min(maximumSuggestionsHeight, min(220, CGFloat((controller.preferences.quickLinks.count + 3) / 4) * 78 + 18)))
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(spacing: 3) {
                                    paletteRow(symbol: isWebAddress ? "globe" : "magnifyingglass",
                                               title: websiteURL?.absoluteString ?? controller.addressText,
                                               subtitle: isWebAddress ? L10n.string("Open Website") : L10n.format("Search with %@", controller.preferences.searchEngine.title),
                                               selected: highlighted == 0) { controller.submitAddress() }
                                        .id(0)
                                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                                        suggestionRow(suggestion, selected: highlighted == index + 1)
                                            .id(index + 1)
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                            .frame(height: min(maximumSuggestionsHeight, CGFloat(suggestions.count + 1) * 58 + CGFloat(suggestions.count) * 3))
                            .onChange(of: highlighted) { _, value in
                                withAnimation(reduceMotion ? nil : BrowserMotion.interaction) {
                                    proxy.scrollTo(value, anchor: .center)
                                }
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.14), radius: 35, y: 14)
        .onExitCommand { controller.dismissAddress() }
        .onChange(of: suggestions.map(\.id)) { _, _ in highlighted = min(highlighted, suggestions.count) }
    }

    private var websiteURL: URL? { BrowserAddressInput.websiteURL(for: controller.addressText) }
    private var isWebAddress: Bool { websiteURL != nil }

    private func submitSelection() {
        if highlighted > 0, suggestions.indices.contains(highlighted - 1) {
            controller.activateSuggestion(suggestions[highlighted - 1])
        } else { controller.submitAddress() }
    }

    private func suggestionRow(_ suggestion: BrowserAddressSuggestion, selected: Bool) -> some View {
        let isOpenTab: Bool = if case .openTab = suggestion { true } else { false }
        return paletteRow(symbol: "rectangle.on.rectangle", iconURL: isOpenTab ? nil : suggestion.url,
                          title: suggestion.title,
                          subtitle: isOpenTab ? L10n.string("Switch to Open Tab") : suggestion.url.absoluteString,
                          selected: selected) { controller.activateSuggestion(suggestion) }
    }

    private func quickLink(_ link: BrowserQuickLink) -> some View {
        Button {
            controller.addressText = link.url.absoluteString
            controller.submitAddress()
        } label: {
            VStack(spacing: 9) {
                QuickLinkIcon(link: link).frame(height: 24)
                Text(link.title).font(.system(size: 11)).lineLimit(1)
            }
            .foregroundStyle(.primary.opacity(0.8))
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(PaletteButtonStyle())
        .help(link.url.absoluteString)
    }

    private func paletteRow(symbol: String, iconURL: URL? = nil, title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if let iconURL { QuickLinkIcon(url: iconURL) }
                    else { Image(systemName: symbol).font(.system(size: 15)) }
                }.frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "return").font(.system(size: 12)).foregroundStyle(.tertiary) }
            }
            .foregroundStyle(.primary)
            .padding(12)
            .frame(height: 58)
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
    private static let logo = Bundle.main.url(forResource: "NewTabLogo", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }
        ?? NSImage(systemSymbolName: "safari", accessibilityDescription: nil)!

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: Self.logo)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.08), radius: 2.5, y: 2)
                .accessibilityHidden(true)

            Text(verbatim: "Nous Browser")
                .font(.custom("InstrumentSerif-Regular", size: 24))
                .foregroundStyle(.primary)
                .frame(height: 24)
                .padding(.top, 12)

            Button(action: controller.showAddress) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 16, height: 18)
                    Text(L10n.string("Search or enter URL"))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 6)
                    Text(verbatim: "⌘L")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(NewTabSearchButtonStyle())
            .frame(maxWidth: 280)
            .accessibilityLabel(L10n.string("Search or enter URL"))
            .help(L10n.string("Search or enter URL") + "  ⌘L")
            .padding(.top, 24)
        }
        // At the reference 600pt window height, the 148pt brand/search group
        // starts at y=192. Keep that balanced placement as the window resizes.
        .padding(.horizontal, 24)
        .padding(.bottom, 68)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .windowDragBackground()
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct NewTabSearchButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .glassEffect(.regular.interactive(), in: Capsule())
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.06), radius: 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.965 : hovered ? 1.025 : 1)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : BrowserMotion.interaction, value: hovered)
            .animation(reduceMotion ? nil : BrowserMotion.interaction, value: configuration.isPressed)
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
        field.placeholderString = L10n.string("Search or enter URL")
        field.font = .systemFont(ofSize: 18)
        field.textColor = .labelColor
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.setAccessibilityLabel(L10n.string("Search or enter URL"))
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.textColor = .labelColor
        if field.stringValue != text { field.stringValue = text }
    }
}
