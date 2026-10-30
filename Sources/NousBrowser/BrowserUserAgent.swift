import Foundation
import WebKit

/// A single desktop WebKit identity, established before any document or request.
/// Site-by-site overrides made HTTP redirects, iframes and new sites disagree
/// with the identity seen by page JavaScript.
@MainActor
enum BrowserUserAgent {
    static func configure(_ configuration: WKWebViewConfiguration) {
        // WebKit owns the platform and AppleWebKit prefix. Its macOS UA uses
        // frozen 605.1.15 compatibility tokens; these are not engine build numbers.
        // Assign instead of appending so inherited popup configurations stay clean.
        configuration.applicationNameForUserAgent =
            "Version/\(compatibilityVersion) Safari/605.1.15 \(applicationToken)"
    }

    /// A tested Safari capability floor, not the installed Safari app's version.
    /// Safari can ship a newer, separately bundled engine than system WKWebView.
    /// Do not derive this from Safari.app or blindly equate OS minor versions.
    /// The 26.4 floor also selects the correct page-zoom/DPR path in web editors.
    static var compatibilityVersion: String {
        if #available(macOS 26.4, *) { return "26.4" }
        return "26.0"
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
}
