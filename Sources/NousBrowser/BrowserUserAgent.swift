import Foundation
import WebKit

@MainActor
enum BrowserUserAgent {
    static func configure(_ configuration: WKWebViewConfiguration) {
        // Keep the system's native embedded-browser identity by default.
        // Only the verified Google and Zoom Slides endpoints below receive a
        // compatibility identity, so their WebKit-specific behavior is enabled.
        // Replace inherited popup suffixes instead of appending to them.
        configuration.applicationNameForUserAgent = applicationToken
    }

    private static var applicationToken: String {
        let bundleVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._-")
        let appVersion = bundleVersion.flatMap { version in
            !version.isEmpty && version.rangeOfCharacter(from: allowed.inverted) == nil ? version : nil
        } ?? "1.0.0"

        return "NousBrowser/\(appVersion)"
    }

    static func needsGoogleSearchCompatibility(_ url: URL?) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), ["google.com", "www.google.com"].contains(host),
              url.user == nil, url.password == nil,
              url.port == nil || url.port == (url.scheme?.lowercased() == "https" ? 443 : 80) else { return false }
        // URL.path drops a trailing slash. Match the actual endpoint rather
        // than broadening the compatibility profile to /search/ or subpaths.
        guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return false }
        return ["", "/", "/webhp", "/search"].contains(path)
    }

    static var supportsModernGoogleWorkspaceCompatibility: Bool {
        if #available(macOS 26.4, *) { return true }
        return false
    }

    static var compatibilityVersion: String {
        supportsModernGoogleWorkspaceCompatibility ? "26.4" : "26.0"
    }

    static func needsGoogleWorkspaceCompatibility(_ url: URL?, supportsModernWorkspace: Bool = supportsModernGoogleWorkspaceCompatibility) -> Bool {
        guard supportsModernWorkspace, let url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              url.port == nil || url.port == (url.scheme?.lowercased() == "https" ? 443 : 80),
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let decodedPath = path.removingPercentEncoding,
              !decodedPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        switch url.host?.lowercased() {
        case "docs.google.com":
            // Docs, Slides and Sheets share Google's editor browser detection.
            // Keep auth, Drive, Forms and unrelated Google paths native.
            return ["/document", "/presentation", "/spreadsheets"].contains {
                path == $0 || path.hasPrefix($0 + "/")
            }
        case "sheets.google.com", "slides.google.com": return true
        case "mail.google.com":
            // Gmail's landing URL redirects into /mail. Apply the same profile
            // before that first request, without extending it to other Google
            // services or the separate accounts.google.com sign-in host.
            return path.isEmpty || path == "/" || path == "/mail" || path.hasPrefix("/mail/")
        default: return false
        }
    }

    static func needsGoogleCompatibility(_ url: URL?) -> Bool {
        needsGoogleSearchCompatibility(url) || needsGoogleWorkspaceCompatibility(url)
    }

    static func needsZoomSlidesCompatibility(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        // Slides' canvas editor suppresses the Enter used to confirm an IME
        // composition only when its UA detector recognizes Safari. A bare
        // WKWebView UA misses that branch and the same Enter adds a newline.
        // The .com and present aliases redirect to slides.zoom.us. Keep login,
        // other Zoom products and unverified regional hosts on the native UA.
        return ["slides.zoom.us", "slides.zoom.com", "present.zoom.us"].contains(host)
    }

    static func needsCompatibility(_ url: URL?) -> Bool {
        needsGoogleCompatibility(url) || needsZoomSlidesCompatibility(url)
    }

    private(set) static var cachedCompatibilityUserAgent: String?
    private static var probeTask: Task<String?, Never>?

    /// Read the real system-generated identity from a separate, empty WebKit
    /// page. The probe neither loads a website nor accesses the user's store.
    static func compatibilityUserAgent() async -> String? {
        if let cachedCompatibilityUserAgent { return cachedCompatibilityUserAgent }
        if let probeTask { return await probeTask.value }
        let task = Task { @MainActor () -> String? in
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configure(configuration)
            let probe = WKWebView(frame: .zero, configuration: configuration)
            defer { probe.stopLoading() }
            guard let native = try? await probe.evaluateJavaScript("navigator.userAgent") as? String else { return nil }
            return safariCompatibilityUserAgent(from: native)
        }
        probeTask = task
        let result = await task.value
        cachedCompatibilityUserAgent = result
        probeTask = nil
        return result
    }

    /// The OS/platform and engine version stay those of the native probe.
    /// Google Sheets applies a legacy outerWidth/innerWidth zoom correction
    /// below Safari 26.4. Cocoa WKWebView can report outerWidth=0, reducing a
    /// Retina canvas to 0.5x. On macOS 26.4+ DPR already includes page zoom;
    /// advertise that capability floor, without claiming newer Safari APIs.
    /// Older systems retain native Google Workspace identity.
    static func safariCompatibilityUserAgent(from native: String) -> String? {
        guard let engine = native.split(separator: " ").first(where: { $0.hasPrefix("AppleWebKit/") })?
            .dropFirst("AppleWebKit/".count), !engine.isEmpty,
              engine.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        let suffix = " " + applicationToken
        let prefix = native.hasSuffix(suffix) ? String(native.dropLast(suffix.count)) : native
        return prefix + " Version/\(compatibilityVersion) Safari/\(engine) " + applicationToken
    }

    /// Per-view decisions are cancellable independently of the shared probe.
    /// Native navigation stays synchronous; only the first compatible-site decision
    /// waits for its real compatibility identity.
    @MainActor final class NavigationPolicy {
        private weak var webView: WKWebView?
        private var compatibilityAgent: String?
        private let resolveCompatibilityUserAgent: @MainActor () async -> String?
        private var generation: UInt64 = 0
        private var task: Task<Void, Never>?
        private var completion: (@MainActor (Bool) -> Void)?

        init(webView: WKWebView, cachedCompatibilityUserAgent: String? = BrowserUserAgent.cachedCompatibilityUserAgent,
             resolveCompatibilityUserAgent: @escaping @MainActor () async -> String? = BrowserUserAgent.compatibilityUserAgent) {
            self.webView = webView
            compatibilityAgent = cachedCompatibilityUserAgent
            self.resolveCompatibilityUserAgent = resolveCompatibilityUserAgent
        }

        func applyKnownIdentity(for url: URL?) {
            invalidate()
            webView?.customUserAgent = BrowserUserAgent.needsCompatibility(url) ? compatibilityAgent : nil
        }

        func prepare(for url: URL, completion: @escaping @MainActor (Bool) -> Void) {
            invalidate()
            guard let webView else { completion(false); return }
            guard BrowserUserAgent.needsCompatibility(url) else {
                webView.customUserAgent = nil
                completion(true)
                return
            }
            if let compatibilityAgent {
                webView.customUserAgent = compatibilityAgent
                completion(true)
                return
            }
            let expectedGeneration = generation
            self.completion = completion
            task = Task { @MainActor [weak self, weak webView] in
                guard let self else { return }
                let agent = await self.resolveCompatibilityUserAgent()
                guard !Task.isCancelled, self.generation == expectedGeneration,
                      let webView, self.webView === webView else { return }
                self.compatibilityAgent = agent
                webView.customUserAgent = agent
                self.task = nil
                let completion = self.completion
                self.completion = nil
                completion?(true)
            }
        }

        func invalidate() {
            generation &+= 1
            task?.cancel()
            task = nil
            let pending = completion
            completion = nil
            pending?(false)
        }
    }
}
