import AppKit

/// System Services menus exist independently of the page engine. Install once
/// at app startup so external-browser shortcuts cannot bypass Nous in Chromium
/// windows or before the first webpage has been created.
@MainActor
final class BrowserServiceMenuFilter: NSObject {
    private static var installed: BrowserServiceMenuFilter?
    private let notificationCenter: NotificationCenter
    private var isFiltering = false

    static func install() {
        guard installed == nil else { return }
        installed = BrowserServiceMenuFilter(initialMenus:
            [NSApp?.mainMenu, NSApp?.servicesMenu].compactMap { $0 })
    }

    init(notificationCenter: NotificationCenter = .default, initialMenus: [NSMenu] = []) {
        self.notificationCenter = notificationCenter
        super.init()
        notificationCenter.addObserver(self, selector: #selector(menuDidUpdate(_:)),
                                       name: NSMenu.didAddItemNotification, object: nil)
        for menu in initialMenus { Self.removeExternalBrowserItems(in: menu) }
    }

    deinit { notificationCenter.removeObserver(self) }

    @objc private func menuDidUpdate(_ notification: Notification) {
        guard !isFiltering, let menu = notification.object as? NSMenu else { return }
        isFiltering = true
        defer { isFiltering = false }
        Self.removeExternalBrowserItems(in: menu)
    }

    /// Services are supplied independently by macOS and may be appended or
    /// reused after a webpage opens its menu. Remove their duplicate browser
    /// commands instead of letting a system service choose a different app.
    static func removeExternalBrowserItems(in menu: NSMenu, nativeSearchFormat: String? = nil,
                                           nativeOpenURLTitle: String? = nil,
                                           nativeReadingListTitle: String? = nil,
                                           nativeOpenTitle: String? = nil) {
        let titles = nativeServiceTitles
        let isServices = menu.title == titles.services || menu.title == "Services"
        let searchFormat = nativeSearchFormat ?? titles.search
        let openURLTitle = nativeOpenURLTitle ?? titles.openURL
        let readingListTitle = nativeReadingListTitle ?? titles.readingList
        let openTitle = nativeOpenTitle ?? titles.open
        for item in menu.items {
            let duplicateSearch = matchesSearchTitle(item.title, format: searchFormat) || matchesSearchTitle(item.title, format: "Search with %@")
            // Finder's generic Open service accepts NSURL and text as well as
            // filenames, so it can also hand a website to another browser.
            let browserService = isServices && (duplicateSearch || [openTitle, "Open", openURLTitle, "Open URL", readingListTitle, "Add to Reading List"].contains(item.title))
            if browserService || item.title.caseInsensitiveCompare(titles.safariViewer) == .orderedSame || item.title == "Open in Safari" {
                menu.removeItem(item)
            } else if let submenu = item.submenu {
                removeExternalBrowserItems(in: submenu, nativeSearchFormat: searchFormat,
                                           nativeOpenURLTitle: openURLTitle, nativeReadingListTitle: readingListTitle,
                                           nativeOpenTitle: openTitle)
            }
        }
    }

    private static let nativeServiceTitles: (services: String, search: String, openURL: String, readingList: String, safariViewer: String, open: String) = {
        let webCore = Bundle(identifier: "com.apple.WebCore")
        let appKit = Bundle(identifier: "com.apple.AppKit")
        let systemUI = Bundle(path: "/System/Library/CoreServices/SystemUIServer.app")
        let finder = Bundle(path: "/System/Library/CoreServices/Finder.app")
        let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari").flatMap { Bundle(url: $0) }
        let openWith = webCore?.localizedString(forKey: "Open with %@", value: "Open with %@", table: nil) ?? "Open with %@"
        return (
            appKit?.localizedString(forKey: "Services", value: "Services", table: nil) ?? "Services",
            webCore?.localizedString(forKey: "Search with %@", value: "Search with %@", table: nil) ?? "Search with %@",
            systemUI?.localizedString(forKey: "Open URL", value: "Open URL", table: "ServicesMenu") ?? "Open URL",
            safari?.localizedString(forKey: "Add to Reading List", value: "Add to Reading List", table: "ServicesMenu") ?? "Add to Reading List",
            openWith.replacingOccurrences(of: "%[tt]@", with: "%@").replacingOccurrences(of: "%@", with: "Safari"),
            (finder?.localizedString(forKey: "Finder/Open", value: "Finder/Open", table: "ServicesMenu") ?? "Finder/Open")
                .components(separatedBy: "/").last ?? "Open"
        )
    }()

    static func matchesSearchTitle(_ title: String, format: String) -> Bool {
        let normalized = format.replacingOccurrences(of: "%[tt]@", with: "%@")
        let parts = normalized.components(separatedBy: "%@")
        guard parts.count == 2 else { return false }
        let pattern = "^" + NSRegularExpression.escapedPattern(for: parts[0]) + ".+" + NSRegularExpression.escapedPattern(for: parts[1]) + "$"
        return title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

}
