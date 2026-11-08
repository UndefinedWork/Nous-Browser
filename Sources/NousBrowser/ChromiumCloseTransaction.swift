import Foundation

/// A close request has one approval phase across ALL of its windows. No page is
/// destroyed while any participant can still reject. The host's native bridge
/// owns beforeunload and invalidates approvals when their document changes.
@MainActor
final class ChromiumCloseTransaction {
    struct Target {
        let id: UUID
        let prepare: (@escaping (Bool) -> Void) -> Void
        let validate: () -> Bool
        let cancel: () -> Void
        let commit: (@escaping (Bool) -> Void) -> Void
    }

    let id: UUID
    private let targets: () -> [Target]?
    private let willCommit: () throws -> Void
    private var completion: ((Bool) -> Void)?
    private var touched: [UUID: Target] = [:]
    private var approved: Set<UUID> = []
    private var pendingCommits: Set<UUID> = []
    private var committing = false
    private var dispatchingCommits = false
    private var commitFailed = false

    init(id: UUID = UUID(), targets: @escaping () -> [Target]?, willCommit: @escaping () throws -> Void = {},
         completion: @escaping (Bool) -> Void) {
        self.id = id
        self.targets = targets
        self.willCommit = willCommit
        self.completion = completion
    }

    func start() { prepareNext() }
    func cancel() { finish(false) }

    private func prepareNext() {
        guard completion != nil, !committing else { return }
        guard let current = targets(), Set(current.map(\.id)).count == current.count else {
            finish(false); return
        }
        // A popup/new window created while a confirmation was open joins this
        // same transaction; never rely on the initial tab count alone.
        if let next = current.first(where: { !approved.contains($0.id) }) {
            touched[next.id] = next
            next.prepare { [weak self] accepted in
                guard let self, self.completion != nil, !self.committing else { return }
                guard accepted else { self.finish(false); return }
                self.approved.insert(next.id)
                self.prepareNext()
            }
            return
        }
        // Validation and all commit dispatches happen in one main-thread turn.
        // Navigation or a self-closed page invalidates its native approval.
        guard current.allSatisfy({ $0.validate() }) else { finish(false); return }
        committing = true
        pendingCommits = Set(current.map(\.id))
        dispatchingCommits = true
        do { try willCommit() }
        catch { finish(false); return }
        // A pre-commit operation may cancel reentrantly. Never dispatch native
        // close after its cancellation has already been reported.
        guard completion != nil else { return }
        for target in current {
            target.commit { [weak self] closed in
                guard let self, self.completion != nil,
                      self.pendingCommits.remove(target.id) != nil else { return }
                if !closed { self.commitFailed = true }
                self.finishCommitIfReady()
            }
        }
        dispatchingCommits = false
        finishCommitIfReady()
    }

    private func finishCommitIfReady() {
        guard !dispatchingCommits, pendingCommits.isEmpty else { return }
        finish(!commitFailed)
    }

    private func finish(_ accepted: Bool) {
        guard let completion else { return }
        self.completion = nil
        // Revoke EVERY approval before reporting cancellation to the UI.
        // Native canceled-waiting tombstones consume a renderer's late ACK.
        if !accepted { for target in touched.values { target.cancel() } }
        touched.removeAll()
        completion(accepted)
    }
}
