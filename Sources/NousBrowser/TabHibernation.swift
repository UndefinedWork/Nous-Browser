import Foundation

/// Decides which background pages to unload. Kept free of WebKit so the
/// policy can be tested directly.
nonisolated enum TabHibernation {
    enum Pressure: Equatable {
        /// Periodic check: unload pages left unused for a long time.
        case idle
        /// The system is low on memory: keep only the most recently used pages.
        case warning
        /// Memory is critically low: unload every background page that allows it.
        case critical
    }

    struct Candidate: Equatable {
        var id: UUID
        var isSelected: Bool
        var isPinned: Bool
        /// Holds a live page; restored-but-unopened and hibernated tabs do not.
        var isLoaded: Bool
        var isCapturingMedia: Bool
        var lastActiveAt: Date
    }

    static let idleInterval: TimeInterval = 30 * 60
    /// Under memory warnings, this many recently used background pages stay loaded.
    static let warningKeepsRecent = 3

    /// Least recently used first, so the oldest pages are unloaded first.
    static func tabsToHibernate(_ tabs: [Candidate], pressure: Pressure, now: Date) -> [UUID] {
        let background = tabs
            .filter { !$0.isSelected && $0.isLoaded && !$0.isCapturingMedia }
            .sorted { $0.lastActiveAt < $1.lastActiveAt }
        switch pressure {
        case .idle:
            // Pinned tabs often hold apps people expect to stay live, such as chat.
            return background
                .filter { !$0.isPinned && now.timeIntervalSince($0.lastActiveAt) >= idleInterval }
                .map(\.id)
        case .warning:
            let unpinned = background.filter { !$0.isPinned }
            return unpinned.dropLast(warningKeepsRecent).map(\.id)
        case .critical:
            return background.map(\.id)
        }
    }
}

/// Runs the hibernation policy on system memory-pressure events and on a
/// periodic idle check. Owned by the app delegate, so tests never start it.
@MainActor
final class TabHibernationMonitor {
    private let model: BrowserModel
    private var memorySource: DispatchSourceMemoryPressure?
    private var idleTimer: Timer?

    init(model: BrowserModel) { self.model = model }

    func start(idleCheckInterval: TimeInterval = 5 * 60) {
        guard memorySource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            MainActor.assumeIsolated {
                self?.run(event.contains(.critical) ? .critical : .warning)
            }
        }
        source.activate()
        memorySource = source
        let timer = Timer(timeInterval: idleCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.run(.idle) }
        }
        timer.tolerance = idleCheckInterval / 5
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    func stop() {
        memorySource?.cancel()
        memorySource = nil
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func run(_ pressure: TabHibernation.Pressure) {
        Task { await model.hibernateBackgroundTabs(for: pressure) }
    }
}
