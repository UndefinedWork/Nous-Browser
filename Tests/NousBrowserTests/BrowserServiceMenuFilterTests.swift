import AppKit
import Testing
@testable import NousBrowser

@Suite("Engine-independent system Services routing", .serialized)
@MainActor
struct BrowserServiceMenuFilterTests {
    @Test func installationFiltersExistingApplicationMenusWithoutCreatingAWebView() {
        let main = NSMenu(title: "Main")
        let services = NSMenu(title: "Services")
        main.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        for title in ["Search With Google", "Open URL", "Add to Reading List", "Open", "Look Up in Dictionary", "Ask Claude"] {
            services.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
        let filter = BrowserServiceMenuFilter(notificationCenter: NotificationCenter(), initialMenus: [main])
        withExtendedLifetime(filter) {
            #expect(services.items.map(\.title) == ["Look Up in Dictionary", "Ask Claude"])
        }
    }

    @Test func lateSystemServicesAreFilteredWithoutTouchingWebSearchOrEditingCommands() {
        let center = NotificationCenter()
        let filter = BrowserServiceMenuFilter(notificationCenter: center)
        let services = NSMenu(title: "Services")
        for title in ["Open URL", "Search with Google", "Make New Sticky Note"] {
            services.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
        center.post(name: NSMenu.didAddItemNotification, object: services)
        #expect(services.items.map(\.title) == ["Make New Sticky Note"])
        let context = NSMenu(title: "Page")
        for title in ["Copy", "Paste", "Search with Google", "Open with Preview", "Open in Safari"] {
            context.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
        center.post(name: NSMenu.didAddItemNotification, object: context)
        withExtendedLifetime(filter) {
            #expect(context.items.map(\.title) == ["Copy", "Paste", "Search with Google", "Open with Preview"])
        }
    }

    @Test func localizedServicesUseTheSameNarrowPolicy() {
        let services = NSMenu(title: "Services")
        for title in ["用Google搜索", "打开 URL", "添加到阅读列表", "打开", "在 Finder 中显示", "词典查询"] {
            services.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
        BrowserServiceMenuFilter.removeExternalBrowserItems(in: services, nativeSearchFormat: "用%@搜索",
            nativeOpenURLTitle: "打开 URL", nativeReadingListTitle: "添加到阅读列表", nativeOpenTitle: "打开")
        #expect(services.items.map(\.title) == ["在 Finder 中显示", "词典查询"])
        #expect(BrowserServiceMenuFilter.matchesSearchTitle("Googleで検索", format: "%[tt]@で検索"))
        #expect(!BrowserServiceMenuFilter.matchesSearchTitle("Googleで検索の設定", format: "%[tt]@で検索"))
    }
}
