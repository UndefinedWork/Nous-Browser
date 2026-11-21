import AppKit
import NousCore
import Observation

struct BrowserExtension: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    let isEnabled: Bool
    let canModify: Bool
    let canRun: Bool
    let hasOptions: Bool
}

@MainActor
@Observable
final class BrowserExtensionStore {
    static let shared = BrowserExtensionStore()
    static let webStoreURL = URL(string: "https://chromewebstore.google.com/")!

    private(set) var extensions: [BrowserExtension] = []
    private(set) var isAvailable = false
    private let center = NBChromiumExtensionCenter.shared()

    private init() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name("NBChromiumExtensionsDidChange"), object: center, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        isAvailable = center.availability().boolValue
        extensions = center.installedExtensions().compactMap { record in
            guard let id = record["id"] as? String, let name = record["name"] as? String else { return nil }
            return BrowserExtension(id: id, name: name, icon: record["icon"] as? NSImage,
                                    isEnabled: record["enabled"] as? Bool ?? false,
                                    canModify: record["canModify"] as? Bool ?? false,
                                    canRun: record["hasAction"] as? Bool ?? false,
                                    hasOptions: record["hasOptions"] as? Bool ?? false)
        }.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    func canRun(_ entry: BrowserExtension, in tab: BrowserTab) -> Bool {
        !tab.isPrivate && entry.isEnabled
            && (entry.hasOptions || (entry.canRun && tab.hasWebContent && tab.webView.window != nil))
    }

    func run(_ entry: BrowserExtension, in tab: BrowserTab) {
        guard canRun(entry, in: tab) else { return }
        let page = tab.hasWebContent ? tab.webView.nativeView : nil
        if let address = center.runExtension(entry.id, inPage: page),
           let url = URL(string: address), url.scheme == "chrome-extension", url.host == entry.id {
            tab.owner?.newTab(url: url)
        }
    }

    func setEnabled(_ enabled: Bool, for entry: BrowserExtension) {
        guard entry.canModify else { return }
        _ = center.setEnabled(NSNumber(value: enabled), forExtension: entry.id)
    }

    func uninstall(_ entry: BrowserExtension, in tab: BrowserTab?) {
        guard entry.canModify, tab?.isPrivate != true,
              let window = tab?.owner?.chromiumPresentationWindow ?? NSApp.keyWindow else { return }
        _ = center.uninstallExtension(entry.id, from: window)
    }
}
