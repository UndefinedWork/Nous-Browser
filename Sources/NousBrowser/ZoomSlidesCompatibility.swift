import Foundation

/// Shared by the navigation identity and the isolated IME guard. Keep this
/// exact-host list aligned with Slides' published SLIDES_HOSTS configuration,
/// including regional redirects; never match every Zoom product or arbitrary
/// hosts containing "slides". Source: https://dg01slides.zoom.us/ (2026-10-28).
enum ZoomSlidesCompatibility {
    static let hosts = [
        "slides.zoom.com", // Public alias.
        "dg01slides.zoom.us", "slides.zoom.us", "gozmslides.zoom.us",
        "us01slides.zoom.us", "us04slides.zoom.us", "us07slides.zoom.us",
        "sg01slides.zoom.us", "au01slides.zoom.us", "ca01slides.zoom.us",
        "eu01slides.zoom.us", "eu02slides.zoom.us", "in01slides.zoom.us", "uk01slides.zoom.us",
        "dg01present.zoom.us", "present.zoom.us", "gozmpresent.zoom.us",
        "us01present.zoom.us", "us04present.zoom.us", "us07present.zoom.us", "us08present.zoom.us",
        "sg01present.zoom.us", "au01present.zoom.us", "ca01present.zoom.us", "sa01present.zoom.us",
        "in01present.zoom.us", "eu01present.zoom.us", "eu02present.zoom.us"
    ]

    static func matches(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }

    // Only compile-time DNS literals are serialized, never page-controlled data.
    static let javaScriptHosts = "[" + hosts.map { "\"\($0)\"" }.joined(separator: ",") + "]"
}
