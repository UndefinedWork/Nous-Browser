import Foundation

/// Credential UI and storage remain native. Chromium receives credentials only
/// after the existing device-authentication flow, in an isolated main-frame world.
@MainActor
enum ChromiumPasswordAutofill {
    static let world = "NousBrowserPasswordAutofill"
    static let binding = "__nousPasswordCandidate"
    static let refreshSource = #"""
    globalThis.__nousBrowserPasswordAutofill?.requestCandidate();
    true;
    """#

    static func attach(to webView: ChromiumPageView,
                       allowLoopbackHTTPForTesting: Bool = false,
                       onCandidate: @escaping (BrowserPasswordAutofill.Candidate?) -> Void) -> Attachment {
        Attachment(webView: webView,
                   allowLoopbackHTTPForTesting: BrowserPasswordAutofill.testingHTTPAllowed(allowLoopbackHTTPForTesting),
                   onCandidate: onCandidate)
    }

    @MainActor
    final class Attachment {
        private weak var webView: ChromiumPageView?
        private var observerID: UUID?
        private var onCandidate: ((BrowserPasswordAutofill.Candidate?) -> Void)?
        private let allowLoopbackHTTPForTesting: Bool
        private var observedURL: URL?
        private(set) var candidate: BrowserPasswordAutofill.Candidate?

        fileprivate init(webView: ChromiumPageView, allowLoopbackHTTPForTesting: Bool,
                         onCandidate: @escaping (BrowserPasswordAutofill.Candidate?) -> Void) {
            self.webView = webView
            self.allowLoopbackHTTPForTesting = allowLoopbackHTTPForTesting
            self.onCandidate = onCandidate
            observedURL = webView.url
            observerID = webView.addEventObserver { [weak self] event, payload in
                self?.receive(event: event, payload: payload)
            }
            webView.nativeView.addScript(
                BrowserPasswordAutofill.detectionSource(allowLoopbackHTTPForTesting: allowLoopbackHTTPForTesting),
                world: ChromiumPasswordAutofill.world, binding: ChromiumPasswordAutofill.binding)
            refreshCandidate()
        }

        func invalidate() {
            if let webView, let observerID { webView.removeEventObserver(observerID) }
            observerID = nil
            clearCandidate()
            onCandidate = nil
            webView = nil
        }

        private func clearCandidate() {
            guard candidate != nil else { return }
            candidate = nil
            onCandidate?(nil)
        }

        func refreshCandidate() {
            guard observerID != nil, let webView, !webView.isLoading, let url = webView.url,
                  BrowserPasswordAutofill.Origin(url: url, allowLoopbackHTTPForTesting: allowLoopbackHTTPForTesting) != nil else { return }
            // The native bridge runs this in the same isolated context that owns
            // the detector. No DOM mutation, credential value, or polling here.
            // state and load-end may both request metadata for the same page.
            // Preserve that page's unused token; navigation/BFCache and a changed
            // form still invalidate it in the detector and native generation.
            webView.nativeView.evaluate(ChromiumPasswordAutofill.refreshSource,
                                        world: ChromiumPasswordAutofill.world) { _, _ in }
        }

        private func receive(event: String, payload: [String: Any]) {
            guard let webView, observerID != nil else { return }
            switch event {
            case "load-start", "closed", "error":
                clearCandidate()
            case "load-end":
                observedURL = webView.url
                refreshCandidate()
            case "state":
                if observedURL != webView.url {
                    observedURL = webView.url
                    clearCandidate()
                    if !webView.isLoading { refreshCandidate() }
                }
            case "binding":
                guard payload["name"] as? String == ChromiumPasswordAutofill.binding else { return }
                receiveCandidate(payload, from: webView)
            default:
                break
            }
        }

        private func receiveCandidate(_ payload: [String: Any], from webView: ChromiumPageView) {
            // These fields come from DevTools execution-context bookkeeping in
            // the native bridge, never from the JavaScript message body. The
            // bridge rejects old contexts, subframes and mismatched world names.
            guard payload["world"] as? String == ChromiumPasswordAutofill.world,
                  payload["isMainFrame"] as? Bool == true,
                  let trustedOriginText = payload["origin"] as? String,
                  let trustedOriginURL = URL(string: trustedOriginText),
                  let trustedOrigin = BrowserPasswordAutofill.Origin(url: trustedOriginURL,
                    allowLoopbackHTTPForTesting: allowLoopbackHTTPForTesting),
                  let serialized = payload["payload"] as? String,
                  serialized.utf8.count <= 40_960,
                  let data = serialized.data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(body.keys) == ["token", "frameURL", "fieldTypes"],
                  let token = body["token"] as? String,
                  let urlText = body["frameURL"] as? String, urlText.utf8.count <= 32_768,
                  let frameURL = URL(string: urlText),
                  let origin = BrowserPasswordAutofill.Origin(url: frameURL,
                    allowLoopbackHTTPForTesting: allowLoopbackHTTPForTesting),
                  trustedOrigin == origin,
                  let currentURL = webView.url, currentURL == frameURL,
                  BrowserPasswordAutofill.Origin(url: currentURL,
                    allowLoopbackHTTPForTesting: allowLoopbackHTTPForTesting) == origin,
                  !webView.isLoading,
                  let fieldTypes = body["fieldTypes"] as? [String] else {
                clearCandidate()
                return
            }
            if token.isEmpty && fieldTypes.isEmpty { clearCandidate(); return }
            guard UUID(uuidString: token) != nil, (1...2).contains(fieldTypes.count),
                  fieldTypes.contains("password"),
                  fieldTypes.allSatisfy({ ["password", "text", "email", "tel"].contains($0) }) else {
                clearCandidate()
                return
            }
            let next = BrowserPasswordAutofill.Candidate(token: token, frameURL: frameURL,
                                                        origin: origin, fieldTypes: fieldTypes)
            guard next != candidate else { return }
            candidate = next
            onCandidate?(next)
        }
    }
}

extension BrowserPasswordAutofill {
    static func fill(_ values: Values, in webView: ChromiumPageView,
                     expectedOrigin: Origin, token: String) async throws -> FillResult {
        try Task.checkCancellation()
        guard !values.password.isEmpty,
              !values.password.contains(where: { $0 == "\r" || $0 == "\n" }),
              values.password.utf8.count <= 65_536, values.username.utf8.count <= 16_384 else {
            throw Failure.invalidCredential
        }
        guard UUID(uuidString: token) != nil, let initialURL = webView.url,
              !webView.isLoading else { throw Failure.staleDocument }
        let allowTestHTTP = testingHTTPAllowed(expectedOrigin.scheme == "http")
        guard Origin(url: initialURL, allowLoopbackHTTPForTesting: allowTestHTTP) == expectedOrigin else {
            throw Failure.invalidOrigin
        }
        let navigation = webView.navigationID
        try Task.checkCancellation()
        let result: Any?
        do {
            // JSON serialization inside the page-view bridge binds the values;
            // passwords are never concatenated into hand-escaped JavaScript.
            result = try await webView.callAsyncJavaScript(
                fillSource,
                arguments: ["username": values.username, "password": values.password,
                            "expectedOrigin": expectedOrigin.serialized, "token": token],
                world: ChromiumPasswordAutofill.world)
        } catch {
            try Task.checkCancellation()
            throw Failure.bridgeUnavailable
        }
        try Task.checkCancellation()
        guard webView.navigationID == navigation, webView.url == initialURL,
              !webView.isLoading else { throw Failure.staleDocument }
        guard let response = result as? [String: Any] else { throw Failure.bridgeUnavailable }
        if response["ok"] as? Bool == true {
            return FillResult(didFillUsername: response["didFillUsername"] as? Bool == true)
        }
        if response["reason"] as? String == "stale" { throw Failure.staleDocument }
        if response["reason"] as? String == "unavailable" { throw Failure.bridgeUnavailable }
        throw Failure.noCompatibleForm
    }
}
