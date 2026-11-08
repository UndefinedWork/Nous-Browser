import Foundation
import Testing
@testable import NousBrowser

@Suite("Page title icon presentation")
struct BrowserPageTitleTests {
    @Test func promotesOneCompleteLeadingEmojiIntoTheIconSlot() {
        for icon in ["⭐", "🗃️", "👩🏽‍💻", "🏳️‍🌈", "🇨🇳", "👍🏽", "☀️", "1️⃣"] {
            let value = BrowserPageTitle(icon + " 排期文档（非早会文档）")
            #expect(value.icon == icon)
            #expect(value.title == "排期文档（非早会文档）")
            #expect(value.icon?.count == 1)
        }
    }

    @Test func acceptsHorizontalSeparatorsWithoutChangingTheRemainingName() {
        for separator in [" ", "   ", "\t", " \t ", "\u{00A0}", "\u{2009}", "\u{3000}"] {
            let value = BrowserPageTitle("⭐" + separator + "Project  Notes 🌙 ")
            #expect(value.icon == "⭐")
            #expect(value.title == "Project  Notes 🌙 ")
        }
    }

    @Test func keepsNormalTitlesAndTextStyleSymbolsIntact() {
        for title in ["Regular page", "1 Topic", "# Topic", "* Topic", "© Copyright", "® Registered", "™ Trademark",
                      "☀ Weather", "⭐\u{FE0E} Text presentation", "✈ Travel", "Privacy Policy | Playyy"] {
            let value = BrowserPageTitle(title)
            #expect(value.icon == nil)
            #expect(value.title == title)
        }
    }

    @Test func requiresAnExactPrefixAndASeparateNonemptyName() {
        for title in ["", "⭐", "⭐ ", "⭐\t\u{00A0}", "⭐Document", "Document ⭐", "Plan ⭐ Notes",
                      " ⭐ Document", "\t⭐ Document", "\u{200B}⭐ Document", "⭐🌙 Document",
                      "⭐\nDocument", "⭐\r\nDocument", "⭐\u{2028}Document", "⭐\u{2029}Document"] {
            let value = BrowserPageTitle(title)
            #expect(value.icon == nil)
            #expect(value.title == title)
        }
    }

    @Test func doesNotPromoteIncompleteEmojiComponents() {
        for title in ["\u{1F3FD} Notes", "\u{1F1E8} Notes", "\u{FE0F} Notes", "\u{200D} Notes",
                      "1\u{FE0F} Notes", "#\u{FE0F} Notes", "*\u{FE0F} Notes"] {
            let value = BrowserPageTitle(title)
            #expect(value.icon == nil)
            #expect(value.title == title)
        }
    }
}

@Suite("Page title presentation preserves browser state", .serialized)
@MainActor
struct BrowserPageTitlePersistenceTests {
    @Test func titleChangesRecomputeThePresentationWithoutMutatingTheSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tab = BrowserTab(title: "⭐ Planning", url: directory.appendingPathComponent("document.html"), owner: nil)
        let model = BrowserModel(sessionURL: directory.appendingPathComponent("session.json"), restoreSession: false,
                                 loadSelectedTab: false, initialTab: tab)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }

        #expect(tab.pageTitle.icon == "⭐")
        #expect(tab.pageTitle.title == "Planning")
        #expect(tab.title == "⭐ Planning")
        #expect(tab.displayTitle == "⭐ Planning")

        tab.title = "👩🏽‍💻 Engineering"
        #expect(tab.pageTitle.icon == "👩🏽‍💻")
        #expect(tab.pageTitle.title == "Engineering")
        #expect(tab.title == "👩🏽‍💻 Engineering")
        #expect(tab.displayTitle == "👩🏽‍💻 Engineering")

        tab.title = "Engineering"
        #expect(tab.pageTitle.icon == nil)
        #expect(tab.pageTitle.title == "Engineering")
        #expect(tab.webView.url == nil)
    }

    @Test func savingAndRestoringKeepsTheRawTitleAndRecreatesItsPresentation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("session.json")
        let rawTitle = "🗃️ Zoom Slides 数据看板"
        let pageURL = directory.appendingPathComponent("local-document.html")
        let originalTab = BrowserTab(title: rawTitle, url: pageURL, isPinned: true, owner: nil)
        let original = BrowserModel(sessionURL: file, restoreSession: false, loadSelectedTab: false,
                                    initialTab: originalTab)
        defer { original.shutdown(); try? FileManager.default.removeItem(at: directory) }
        original.persistSession()

        let stored = try JSONDecoder().decode(BrowserSession.self, from: Data(contentsOf: file))
        #expect(stored.tabs.count == 1)
        #expect(stored.tabs[0].title == rawTitle)
        #expect(stored.tabs[0].url == pageURL)

        let restored = BrowserModel(sessionURL: file, loadSelectedTab: false)
        defer { restored.shutdown() }
        let tab = try #require(restored.selectedTab)
        #expect(tab.id == originalTab.id)
        #expect(tab.title == rawTitle)
        #expect(tab.displayTitle == rawTitle)
        #expect(tab.pageTitle.icon == "🗃️")
        #expect(tab.pageTitle.title == "Zoom Slides 数据看板")
        #expect(tab.webView.url == nil)
        restored.persistSession()
        let savedAgain = try JSONDecoder().decode(BrowserSession.self, from: Data(contentsOf: file))
        #expect(savedAgain.tabs[0].title == rawTitle)
    }
}
