import Foundation
import WebKit

@MainActor
enum BrowserUserAgent {
    static func configure(_ configuration: WKWebViewConfiguration) {
        let bundleVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._-")
        let appVersion = bundleVersion.flatMap { version in
            !version.isEmpty && version.rangeOfCharacter(from: allowed.inverted) == nil ? version : nil
        } ?? "1.0.0"

        // macOS WKWebView supplies its real native prefix. Safari-compatible
        // tokens prevent sites from treating its unversioned default as legacy.
        // 26.0 is a conservative compatibility floor for our macOS 26 target,
        // rather than a claim about the separately installed Safari app.
        // Replace the inherited suffix so popup configurations stay idempotent.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15 NousBrowser/\(appVersion)"
    }
}
