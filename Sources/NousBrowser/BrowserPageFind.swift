import AppKit
import Observation
import SwiftUI
import WebKit

@MainActor
@Observable
final class BrowserPageFindController {
    typealias Completion = @MainActor @Sendable (Bool) -> Void
    typealias FindOperation = @MainActor (WKWebView, String, WKFindConfiguration, @escaping Completion) -> Void

    @ObservationIgnored weak var model: BrowserModel?
    var isPresented = false
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            invalidateSearch()
            matchFound = nil
            scheduleSearch()
        }
    }
    var focusToken = UUID()
    var matchFound: Bool?

    @ObservationIgnored private let findOperation: FindOperation
    @ObservationIgnored private let debounceInterval: Duration
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var isShutDown = false

    private struct PageIdentity: Equatable {
        let tabID: UUID
        let webViewID: ObjectIdentifier
        let webURL: URL?
        let tabURL: URL?
    }

    init(model: BrowserModel, debounceInterval: Duration = .milliseconds(180),
         findOperation: @escaping FindOperation = { view, query, configuration, completion in
             view.find(query, configuration: configuration) { completion($0.matchFound) }
         }) {
        self.model = model
        self.debounceInterval = debounceInterval
        self.findOperation = findOperation
    }

    func present() {
        guard !isShutDown, model?.selectedTab?.hasWebContent == true else { return }
        let wasPresented = isPresented
        isPresented = true
        focusToken = UUID()
        if !wasPresented {
            invalidateSearch()
            matchFound = nil
            scheduleSearch()
        }
    }

    func dismiss() {
        isPresented = false
        invalidateSearch()
        matchFound = nil
        if let view = model?.selectedTab?.webView, let window = view.window,
           window.isKeyWindow, window.attachedSheet == nil {
            window.makeFirstResponder(view)
        }
        // Public WKWebView.find("") is a no-op for document selection, so do
        // not claim to clear it or use WebKit's private find-UI selectors.
    }

    func findNext(backward: Bool = false) {
        guard !isShutDown, model?.selectedTab?.hasWebContent == true else { return }
        guard !text.isEmpty else { present(); return }
        if !isPresented { isPresented = true; focusToken = UUID() }
        invalidateSearch()
        performSearch(backward: backward)
    }

    /// Called for tab, URL and loading changes. A same-URL reload also
    /// invalidates pending results; its completion triggers a fresh query.
    func pageDidChange() {
        guard model?.selectedTab?.hasWebContent == true else { dismiss(); return }
        invalidateSearch()
        matchFound = nil
        scheduleSearch()
    }

    func shutdown() {
        isShutDown = true
        invalidateSearch()
        isPresented = false
        matchFound = nil
        text = ""
        model = nil
    }

    private var pageIdentity: PageIdentity? {
        guard let tab = model?.selectedTab, tab.hasWebContent, !tab.isLoading, !tab.webView.isLoading,
              tab.errorDescription == nil else { return nil }
        return PageIdentity(tabID: tab.id, webViewID: ObjectIdentifier(tab.webView),
                            webURL: tab.webView.url, tabURL: tab.url)
    }

    private func invalidateSearch() {
        requestID = UUID()
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func scheduleSearch() {
        guard !isShutDown, isPresented, !text.isEmpty, let identity = pageIdentity else { return }
        let request = requestID
        let interval = debounceInterval
        debounceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: interval) }
            catch { return }
            guard !Task.isCancelled, let self, self.requestID == request,
                  self.pageIdentity == identity else { return }
            self.debounceTask = nil
            self.performSearch(backward: false)
        }
    }

    private func performSearch(backward: Bool) {
        guard !isShutDown, isPresented, !text.isEmpty, let identity = pageIdentity,
              let view = model?.selectedTab?.webView else { return }
        let request = requestID
        let query = text
        let configuration = WKFindConfiguration()
        configuration.caseSensitive = false
        configuration.wraps = true
        configuration.backwards = backward
        matchFound = nil
        findOperation(view, query, configuration) { [weak self] found in
            guard let self, !self.isShutDown, self.isPresented, self.requestID == request,
                  self.text == query, self.pageIdentity == identity else { return }
            self.matchFound = found
        }
    }
}

struct BrowserPageFindBar: View {
    @Bindable var find: BrowserPageFindController

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                PageFindInput(text: $find.text, focusToken: find.focusToken,
                              next: { find.findNext() }, previous: { find.findNext(backward: true) },
                              cancel: find.dismiss)
                    .frame(minWidth: 80, maxWidth: .infinity)
                    .frame(height: 22)
                if find.matchFound == false && !find.text.isEmpty {
                    Text(L10n.string("No matches")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Button { find.findNext(backward: true) } label: { Image(systemName: "chevron.up").frame(width: 22, height: 22) }
                .help(L10n.string("Find Previous"))
                .accessibilityLabel(L10n.string("Find Previous"))
                .disabled(find.text.isEmpty)
            Button { find.findNext() } label: { Image(systemName: "chevron.down").frame(width: 22, height: 22) }
                .help(L10n.string("Find Next"))
                .accessibilityLabel(L10n.string("Find Next"))
                .disabled(find.text.isEmpty)
            Button(action: find.dismiss) { Image(systemName: "xmark").frame(width: 22, height: 22) }
                .help(L10n.string("Close Find"))
                .accessibilityLabel(L10n.string("Close Find"))
        }
        .font(.system(size: 11, weight: .medium))
        .buttonStyle(.plain)
        .padding(10)
        .frame(maxWidth: 360)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onExitCommand(perform: find.dismiss)
    }
}

struct PageFindInput: NSViewRepresentable {
    @Binding var text: String
    let focusToken: UUID
    let next: () -> Void
    let previous: () -> Void
    let cancel: () -> Void

    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusAndSelect()
        }

        func focusAndSelect() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, window.isKeyWindow else { return }
                window.makeFirstResponder(self)
                self.selectText(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PageFindInput
        var token: UUID
        init(_ parent: PageFindInput) { self.parent = parent; token = parent.focusToken }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Candidate confirmation/navigation belongs to the native editor.
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                 #selector(NSResponder.insertLineBreak(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { parent.previous() }
                else { parent.next() }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.cancel()
                return true
            default: return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.stringValue = text
        field.placeholderString = L10n.string("Search this page")
        field.setAccessibilityLabel(L10n.string("Search this page"))
        field.font = .systemFont(ofSize: 12)
        field.textColor = .labelColor
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.textColor = .labelColor
        // The field value/binding may lag the editor while an IME owns marked
        // text. Reassigning stringValue here discards that composition.
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true,
           field.stringValue != text { field.stringValue = text }
        if context.coordinator.token != focusToken {
            context.coordinator.token = focusToken
            field.focusAndSelect()
        }
    }
}
