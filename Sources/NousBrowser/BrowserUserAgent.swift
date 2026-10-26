import Foundation
import WebKit

@MainActor
enum BrowserUserAgent {
    static func configure(_ configuration: WKWebViewConfiguration) {
        // Keep the system's native embedded-browser identity by default.
        // Only the Google endpoints below receive a compatibility identity.
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

    static var supportsModernSheetsCompatibility: Bool {
        if #available(macOS 26.4, *) { return true }
        return false
    }

    static var compatibilityVersion: String {
        supportsModernSheetsCompatibility ? "26.4" : "26.0"
    }

    static func needsGoogleSheetsCompatibility(_ url: URL?, supportsModernSheets: Bool = supportsModernSheetsCompatibility) -> Bool {
        guard supportsModernSheets, let url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              url.port == nil || url.port == (url.scheme?.lowercased() == "https" ? 443 : 80),
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let decodedPath = path.removingPercentEncoding,
              !decodedPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        switch url.host?.lowercased() {
        case "docs.google.com": return path == "/spreadsheets" || path.hasPrefix("/spreadsheets/")
        case "sheets.google.com": return true
        default: return false
        }
    }

    static func needsGoogleCompatibility(_ url: URL?) -> Bool {
        needsGoogleSearchCompatibility(url) || needsGoogleSheetsCompatibility(url)
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
            return googleSearchUserAgent(from: native)
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
    /// Older systems retain the Search-only profile and native Sheets identity.
    static func googleSearchUserAgent(from native: String) -> String? {
        guard let engine = native.split(separator: " ").first(where: { $0.hasPrefix("AppleWebKit/") })?
            .dropFirst("AppleWebKit/".count), !engine.isEmpty,
              engine.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        let suffix = " " + applicationToken
        let prefix = native.hasSuffix(suffix) ? String(native.dropLast(suffix.count)) : native
        return prefix + " Version/\(compatibilityVersion) Safari/\(engine) " + applicationToken
    }

    /// Per-view decisions are cancellable independently of the shared probe.
    /// Native navigation stays synchronous; only the first Search decision
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
            webView?.customUserAgent = BrowserUserAgent.needsGoogleCompatibility(url) ? compatibilityAgent : nil
        }

        func prepare(for url: URL, completion: @escaping @MainActor (Bool) -> Void) {
            invalidate()
            guard let webView else { completion(false); return }
            guard BrowserUserAgent.needsGoogleCompatibility(url) else {
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
