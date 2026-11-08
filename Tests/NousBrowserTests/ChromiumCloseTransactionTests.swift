import AppKit
import Foundation
import Testing
@testable import NousBrowser

@Suite("Atomic Chromium window close", .serialized)
@MainActor
struct ChromiumCloseTransactionTests {
    final class Page {
        let id = UUID()
        let instance = UUID()
        var draft = "unsaved text"
        var answer: ((Bool) -> Void)?
        var valid = true
        var canceled = false
        var committed = false
        var commitSucceeds = true
        var prepares = 0
        var target: ChromiumCloseTransaction.Target {
            .init(id: id, prepare: { self.prepares += 1; self.answer = $0 },
                  validate: { self.valid && !self.canceled },
                  cancel: { self.canceled = true },
                  commit: { self.committed = true; $0(self.commitSucceeds) })
        }
    }

    @Test func laterWindowCancelPreservesEveryPageAndCancelsBeforeCallback() {
        let first = Page(), second = Page(), third = Page()
        let pages = [first, second, third]
        let identities = pages.map(\.instance)
        var result: Bool?
        let tx = ChromiumCloseTransaction(targets: { pages.map(\.target) }) { accepted in
            #expect(first.canceled && second.canceled)
            result = accepted
        }
        tx.start(); first.answer?(true)
        #expect(!first.committed && result == nil)
        second.answer?(false)
        #expect(result == false)
        #expect(pages.allSatisfy { !$0.committed && $0.draft == "unsaved text" })
        #expect(pages.map(\.instance) == identities)
        #expect(third.prepares == 0)
        second.answer?(true) // A late native callback cannot restart commit.
        #expect(pages.allSatisfy { !$0.committed })
    }

    @Test func newPageWhileWaitingMustAlsoApprove() {
        let first = Page(), added = Page()
        var pages = [first]
        var result: Bool?
        let tx = ChromiumCloseTransaction(targets: { pages.map(\.target) }) { result = $0 }
        tx.start(); pages.append(added); first.answer?(true)
        #expect(added.prepares == 1 && !first.committed && result == nil)
        added.answer?(true)
        #expect(result == true && first.committed && added.committed)
    }

    @Test func navigationInvalidationPreventsAnyCommit() {
        let first = Page(), second = Page()
        var result: Bool?
        let tx = ChromiumCloseTransaction(targets: { [first.target, second.target] }) { result = $0 }
        tx.start(); first.answer?(true); first.valid = false; second.answer?(true)
        #expect(result == false && first.canceled && second.canceled)
        #expect(!first.committed && !second.committed)
    }

    @Test func preexistingCloseOrMissingNativeCapabilityFailsWithoutDestroying() {
        let page = Page()
        var result: Bool?
        let conflicting = ChromiumCloseTransaction(targets: { nil }) { result = $0 }
        conflicting.start()
        #expect(result == false && !page.committed)
        let unavailable = ChromiumCloseTransaction(targets: { [page.target] }) { result = $0 }
        unavailable.start(); page.answer?(false)
        #expect(result == false && page.canceled && !page.committed)
    }

    @Test func actualCommitFailureNeverReportsSuccess() {
        let first = Page(), second = Page()
        second.commitSucceeds = false
        var result: Bool?
        let tx = ChromiumCloseTransaction(targets: { [first.target, second.target] }) { result = $0 }
        tx.start(); first.answer?(true); second.answer?(true)
        #expect(result == false && first.canceled && second.canceled)
    }

    @Test func cancellationWhileRendererIsPendingCannotCommitLateApproval() {
        let page = Page()
        var results: [Bool] = []
        let tx = ChromiumCloseTransaction(targets: { [page.target] }) { results.append($0) }
        tx.start(); tx.cancel(); page.answer?(true)
        #expect(results == [false] && page.canceled && !page.committed)
    }

    @Test func saveFailureRevokesEveryApprovalBeforeReportingCancellation() {
        enum SaveFailure: Error { case denied }
        let first = Page(), second = Page()
        let identities = [first.instance, second.instance]
        var saves = 0
        var results: [Bool] = []
        let tx = ChromiumCloseTransaction(targets: { [first.target, second.target] }, willCommit: {
            #expect(first.prepares == 1 && second.prepares == 1)
            #expect(!first.committed && !second.committed)
            saves += 1
            throw SaveFailure.denied
        }) { accepted in
            #expect(first.canceled && second.canceled)
            results.append(accepted)
        }
        tx.start(); first.answer?(true)
        #expect(saves == 0 && results.isEmpty)
        second.answer?(true)
        #expect(saves == 1 && results == [false])
        #expect(!first.committed && !second.committed)
        #expect([first.instance, second.instance] == identities)
        #expect(first.draft == "unsaved text" && second.draft == "unsaved text")
        first.answer?(true); second.answer?(true)
        #expect(results == [false] && saves == 1 && !first.committed && !second.committed)
    }

    @Test func successfulSaveRunsAfterAllApprovalsAndBeforeAnyCommit() {
        let first = Page(), second = Page()
        var saved = false
        var results: [Bool] = []
        func target(_ page: Page) -> ChromiumCloseTransaction.Target {
            let original = page.target
            return .init(id: original.id, prepare: original.prepare, validate: original.validate,
                         cancel: original.cancel, commit: { answer in
                #expect(saved)
                original.commit(answer)
            })
        }
        let tx = ChromiumCloseTransaction(targets: { [target(first), target(second)] }, willCommit: {
            #expect(first.prepares == 1 && second.prepares == 1)
            #expect(!first.committed && !second.committed)
            saved = true
        }) { results.append($0) }
        tx.start(); first.answer?(true)
        #expect(!saved)
        second.answer?(true)
        #expect(saved && results == [true] && first.committed && second.committed)
    }

    @Test func reentrantCancellationDuringSaveDoesNotDispatchClose() {
        let page = Page()
        var results: [Bool] = []
        var tx: ChromiumCloseTransaction?
        tx = ChromiumCloseTransaction(targets: { [page.target] }, willCommit: {
            tx?.cancel()
        }) { results.append($0) }
        tx?.start(); page.answer?(true)
        #expect(results == [false] && page.canceled && !page.committed)
        tx = nil
    }

    @Test func partialNativeFailureRemovesOnlyActuallyClosedModelTabs() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = BrowserModel(sessionURL: directory.appendingPathComponent("session.json"),
                                 restoreSession: false, loadSelectedTab: false, startWithBlankTab: true)
        defer { model.shutdown() }
        model.newTab()
        let first = try #require(model.tabs.first)
        let survivor = try #require(model.tabs.last)
        let transactionID = UUID()
        var targets = try #require(model.targetsForWindowClose(transactionID))
        let original = targets[1]
        targets[1] = .init(id: original.id, prepare: original.prepare, validate: original.validate,
                           cancel: original.cancel, commit: { $0(false) })
        var results: [Bool] = []
        let tx = ChromiumCloseTransaction(id: transactionID, targets: { targets }, willCommit: {
            model.approveWindowClose(transactionID)
        }) { accepted in
            model.finishWindowClose(transactionID, committed: accepted)
            results.append(accepted)
        }
        tx.start()
        #expect(results == [false])
        #expect(model.tabs.count == 1 && model.tabs.first === survivor)
        #expect(first.owner == nil)
        #expect(survivor.owner === model)
        #expect(model.canAdoptTransferredTab(withID: UUID()))
    }
}
