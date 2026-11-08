import AppKit

import NousCore

typealias BrowserPageView = ChromiumPageView

/// Swift boundary for the native Chromium child view. Editing, IME, file drops,
/// compositing and accessibility remain Chromium/AppKit operations.
@MainActor
final class ChromiumPageView: NBChromiumView {
    enum FullscreenState { case notInFullscreen, inFullscreen }
    struct FindResult { let matchFound: Bool }

    var nativeView: NBChromiumView { self }
    var url: URL? { urlString.isEmpty ? nil : URL(string: urlString) }
    var title: String? { pageTitle.isEmpty ? nil : pageTitle }
    var isLoading: Bool { loading }
    var pageZoom: CGFloat {
        get { CGFloat(zoomFactor) }
        set { zoomFactor = Double(newValue) }
    }
    var fullscreenState: FullscreenState { fullscreen ? .inFullscreen : .notInFullscreen }
    private(set) var navigationID = UUID()
    private var observers: [UUID: (String, [String: Any]) -> Void] = [:]
    private struct PendingEvent {
        let name: String
        let payload: [String: Any]
        let navigationID: UUID?
    }
    private var pendingEvents: [PendingEvent] = []
    private var eventDeliveryScheduled = false
    private var nativeDidClose = false
    private var closeCallbacks: [@MainActor (Bool) -> Void] = []
    private var lastFindQuery: String?
    private var isClosed = false
    private weak var pendingFocusWindow: NSWindow?
    private var pendingFocusIsCurrent: (() -> Bool)?
    private var focusDeliveryScheduled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        eventHandler = { [weak self] event, payload in
            MainActor.assumeIsolated {
                self?.enqueue(event, payload: payload)
            }
        }
    }

    private func enqueue(_ event: String, payload: [String: Any]) {
        guard !isClosed else { return }
        // Invalidate in-flight operations immediately, including a same-URL
        // reload. Observable tab changes are delivered after AppKit/SwiftUI has
        // finished mounting or moving the native view.
        if event == "load-start" || event == "closed" || event == "discarded" {
            navigationID = UUID()
            lastFindQuery = nil
        }
        if event == "closed" { nativeDidClose = true }
        if event == "load-end" { recordLocalDisplayDiagnosticsIfRequested() }
        let survivesNavigation = event == "closed" || event.hasPrefix("download-")
        let pending = PendingEvent(name: event, payload: payload,
                                   navigationID: survivesNavigation ? nil : navigationID)
        if ["state", "progress"].contains(event),
           let previous = pendingEvents.last, previous.name == event,
           previous.navigationID == pending.navigationID {
            pendingEvents[pendingEvents.count - 1] = pending
        } else { pendingEvents.append(pending) }
        guard !eventDeliveryScheduled else { return }
        eventDeliveryScheduled = true
        DispatchQueue.main.async { [weak self] in self?.deliverPendingEvents() }
    }

    /// Explicit, local-fixture-only diagnostics for native compositing failures.
    /// No page content is collected during ordinary browsing.
    private func recordLocalDisplayDiagnosticsIfRequested() {
        guard Bundle.main.bundleIdentifier == "com.cellier.nous-browser.chromium-preview",
              let directory = ProcessInfo.processInfo.environment["NOUS_CHROMIUM_DISPLAY_DIAGNOSTICS"],
              let target = url, target.host == "127.0.0.1",
              (target.port == 18869 && target.path == "/chromium_download_unload.html")
                || (target.port == 8879 && target.path == "/") else { return }
        let generation = navigationID
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !self.isClosed, self.navigationID == generation, self.url == target else { return }
            @MainActor func describe(_ view: NSView, depth: Int = 0) -> [String: Any] {
                var value: [String: Any] = ["class": view.className, "frame": NSStringFromRect(view.frame),
                    "bounds": NSStringFromRect(view.bounds), "visibleRect": NSStringFromRect(view.visibleRect),
                    "hidden": view.isHidden, "hiddenAncestor": view.isHiddenOrHasHiddenAncestor,
                    "alpha": view.alphaValue, "window": view.window?.windowNumber ?? -1,
                    "layerOpacity": view.layer?.opacity ?? 1]
                if depth < 12 { value["children"] = view.subviews.map { describe($0, depth: depth + 1) } }
                return value
            }
            var state: [String: Any] = ["view": describe(self),
                "keyWindow": NSApp.keyWindow?.windowNumber ?? -1,
                "firstResponder": self.window?.firstResponder?.className ?? "none"]
            if let window = self.window {
                state["window"] = ["visible": window.isVisible, "miniaturized": window.isMiniaturized,
                    "occlusion": window.occlusionState.rawValue, "frame": NSStringFromRect(window.frame)]
                if let content = window.contentView {
                    let center = self.convert(NSPoint(x: self.bounds.midX, y: self.bounds.midY), to: content.superview)
                    let hit = content.hitTest(center)
                    state["centerHit"] = ["class": hit?.className ?? "none",
                        "belongsToPage": hit.map { $0 === self || $0.isDescendant(of: self) } ?? false]
                }
            }
            var ancestors: [[String: Any]] = []
            var parent = self.superview
            while let view = parent {
                ancestors.append(["class": view.className, "hidden": view.isHidden,
                    "alpha": view.alphaValue, "frame": NSStringFromRect(view.frame)])
                parent = view.superview
            }
            state["ancestors"] = ancestors
            do {
                state["document"] = try await self.evaluateScript("JSON.stringify({visibility:document.visibilityState,width:innerWidth,height:innerHeight,dpr:devicePixelRatio,elements:document.body?.childElementCount,bodyRect:document.body?.getBoundingClientRect().toJSON()})", world: "NousLocalDisplayDiagnostics")
            } catch { state["documentError"] = String(describing: error) }
            let destination = URL(fileURLWithPath: directory, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let stem = generation.uuidString
                let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: destination.appendingPathComponent(stem + ".json"), options: .atomic)
                let screenshot = try await self.captureImage()
                try screenshot.write(to: destination.appendingPathComponent(stem + ".png"), options: .atomic)
            } catch { NSLog("Nous local display diagnostic failed: %@", String(describing: error)) }
        }
    }

    private func deliverPendingEvents() {
        eventDeliveryScheduled = false
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        for event in events {
            guard !isClosed else { return }
            guard event.navigationID == nil || event.navigationID == navigationID else { continue }
            // An earlier observer may close the tab or detach another observer.
            // Never invoke callbacks retained from the former page ownership.
            for id in Array(observers.keys) {
                guard !isClosed else { return }
                observers[id]?(event.name, event.payload)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        guard !isClosed else { return false }
        focusBrowser()
        return true
    }

    override var isHidden: Bool {
        didSet {
            setPageVisible(!isHidden && window != nil)
            scheduleTransferredFocus()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setPageVisible(!isHidden && window != nil)
        scheduleTransferredFocus()
    }

    /// SwiftUI mounts a transferred native page after the model transaction.
    /// Never make a detached page the window's first responder.
    func requestTransferredFocus(in destination: NSWindow, isCurrent: @escaping () -> Bool) {
        pendingFocusWindow = destination
        pendingFocusIsCurrent = isCurrent
        scheduleTransferredFocus()
    }

    private func scheduleTransferredFocus() {
        guard !focusDeliveryScheduled, pendingFocusIsCurrent != nil else { return }
        focusDeliveryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusDeliveryScheduled = false
            guard !self.isClosed, let destination = self.pendingFocusWindow,
                  self.pendingFocusIsCurrent?() == true, destination.isKeyWindow else {
                self.pendingFocusWindow = nil
                self.pendingFocusIsCurrent = nil
                return
            }
            guard self.window === destination, !self.isHiddenOrHasHiddenAncestor else { return }
            self.pendingFocusWindow = nil
            self.pendingFocusIsCurrent = nil
            destination.makeFirstResponder(self)
        }
    }

    @discardableResult
    func addEventObserver(_ observer: @escaping (String, [String: Any]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeEventObserver(_ id: UUID) { observers[id] = nil }

    func load(_ request: URLRequest) {
        guard !isClosed, let url = request.url else { return }
        loadURL(url.absoluteString)
    }
    func reload() { reloadBypassingCache(false) }
    func reloadFromOrigin() { reloadBypassingCache(true) }

    func navigationDestination(backwards: Bool) async throws -> URL? {
        guard !isClosed else { throw ChromiumPageError.closed }
        let generation = navigationID
        return try await withCheckedThrowingContinuation { continuation in
            navigationURLBackwards(backwards) { [weak self] address, error in
                MainActor.assumeIsolated {
                    guard let self, !self.isClosed, self.navigationID == generation else {
                        continuation.resume(throwing: ChromiumPageError.staleDocument)
                        return
                    }
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: address.flatMap(URL.init(string:))) }
                }
            }
        }
    }

    /// A user close must run Chromium's beforeunload flow before the model or
    /// native host is removed. Multiple close commands share one native request.
    func requestPageClose(completion: @escaping @MainActor (Bool) -> Void) {
        if ProcessInfo.processInfo.environment["NOUS_CHROMIUM_TRACE"] != nil {
            NSLog("Nous Chromium: request page close, shutdown=%d nativeClosed=%d callbacks=%ld", isClosed, nativeDidClose, closeCallbacks.count)
        }
        guard !isClosed, !nativeDidClose else {
            DispatchQueue.main.async { completion(true) }
            return
        }
        closeCallbacks.append(completion)
        guard closeCallbacks.count == 1 else { return }
        requestClose { [weak self] accepted in
            MainActor.assumeIsolated {
                guard let self else { return }
                if accepted { self.nativeDidClose = true }
                // Never remove an NSView from inside CEF's close callback.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let callbacks = self.closeCallbacks
                    self.closeCallbacks.removeAll()
                    for callback in callbacks { callback(accepted) }
                }
            }
        }
    }

    func shutdown() {
        guard !isClosed else { return }
        isClosed = true
        pendingFocusWindow = nil
        pendingFocusIsCurrent = nil
        navigationID = UUID()
        pendingEvents.removeAll()
        observers.removeAll()
        let callbacks = closeCallbacks
        closeCallbacks.removeAll()
        if !callbacks.isEmpty {
            DispatchQueue.main.async { for callback in callbacks { callback(true) } }
        }
        eventHandler = nil
        popupHandler = nil
        closeBrowser()
        removeFromSuperview()
    }

    func evaluateScript(_ source: String, world: String) async throws -> Any? {
        guard !isClosed else { throw ChromiumPageError.closed }
        let generation = navigationID
        let data: Data? = try await withCheckedThrowingContinuation { continuation in
            evaluate(source, world: world) { [weak self] result, error in
                MainActor.assumeIsolated {
                    guard let self, !self.isClosed, self.navigationID == generation else {
                        continuation.resume(throwing: ChromiumPageError.staleDocument)
                        return
                    }
                    if let error { continuation.resume(throwing: error) }
                    else if let result {
                        do {
                            let data = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
                            continuation.resume(returning: data)
                        } catch { continuation.resume(throwing: error) }
                    } else { continuation.resume(returning: nil) }
                }
            }
        }
        return try data.map { try JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
    }

    /// Arguments are encoded as JSON, never interpolated as JavaScript source.
    /// Isolated worlds preserve per-document state without exposing it to a site.
    func callAsyncJavaScript(_ body: String, arguments: [String: Any], world: String) async throws -> Any? {
        let keys = arguments.keys.sorted()
        guard keys.allSatisfy({ $0.range(of: "^[A-Za-z_$][A-Za-z0-9_$]*$", options: .regularExpression) != nil }) else {
            throw ChromiumPageError.invalidArguments
        }
        let data = try JSONSerialization.data(withJSONObject: keys.map { arguments[$0]! }, options: [.fragmentsAllowed])
        guard let encoded = String(data: data, encoding: .utf8) else { throw ChromiumPageError.invalidArguments }
        return try await evaluateScript("(async function(\(keys.joined(separator: ","))){\n\(body)\n})(...\(encoded))", world: world)
    }

    func captureImage() async throws -> Data {
        guard !isClosed else { throw ChromiumPageError.closed }
        let generation = navigationID
        return try await withCheckedThrowingContinuation { continuation in
            capturePNG { [weak self] data, error in
                MainActor.assumeIsolated {
                    guard let self, !self.isClosed, self.navigationID == generation else {
                        continuation.resume(throwing: ChromiumPageError.staleDocument)
                        return
                    }
                    if let error { continuation.resume(throwing: error) }
                    else if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: ChromiumPageError.unavailable) }
                }
            }
        }
    }

    func find(_ query: String, configuration: BrowserFindConfiguration,
              completion: @escaping @MainActor @Sendable (FindResult) -> Void) {
        let next = lastFindQuery == query
        lastFindQuery = query
        findText(query, backwards: configuration.backwards, next: next) { found in
            MainActor.assumeIsolated { completion(FindResult(matchFound: found)) }
        }
    }
}

enum ChromiumPageError: Error {
    case closed, staleDocument, invalidArguments, unavailable
}
