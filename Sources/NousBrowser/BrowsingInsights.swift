import AppKit
import CoreGraphics
import Foundation
import Observation

// MARK: - Recorded data

/// One local calendar day of browsing activity. Only site domains are kept,
/// never full addresses or page titles.
nonisolated struct InsightsDay: Codable, Equatable, Sendable {
    struct Site: Codable, Equatable, Sendable {
        var seconds: Double = 0
        var visits = 0
    }

    /// Seconds of active browsing: Nous in front and the Mac in use.
    var active: Double = 0
    /// Active seconds per hour of the day (0–23).
    var hours = [Double](repeating: 0, count: 24)
    var sites: [String: Site] = [:]
    /// Active seconds per space ID.
    var spaces: [String: Double] = [:]
    var visits = 0
    var searches = 0
    var tabsOpened = 0
    var tabsClosed = 0
    var tabSwitches = 0
    var spaceSwitches = 0
    /// Changes of site during active browsing.
    var siteSwitches = 0
    /// Separate browsing sessions (after 5+ minutes away).
    var sessions = 0
    /// Uninterrupted stretches on one site lasting a minute or more.
    var focusStretches = 0
    var focusSeconds: Double = 0
    var longestFocus: Double = 0
    var longestFocusSite: String?
}

nonisolated struct InsightsLog: Codable, Equatable, Sendable {
    var version = 1
    /// Keyed by `yyyy-MM-dd` in the local calendar.
    var days: [String: InsightsDay] = [:]

    static let retainedDays = 400

    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func day(_ date: Date, calendar: Calendar = .current) -> InsightsDay? {
        days[Self.key(for: date, calendar: calendar)]
    }

    /// The first day anything was recorded.
    var firstDayKey: String? { days.keys.min() }

    mutating func prune(now: Date, calendar: Calendar = .current) {
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.retainedDays, to: now) else { return }
        let oldest = Self.key(for: cutoff, calendar: calendar)
        days = days.filter { $0.key >= oldest }
    }

    /// The site a URL is filed under: its domain without `www.`.
    static func site(for url: URL?) -> String? {
        guard let url else { return nil }
        if url.isFileURL { return "file" }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), var host = url.host?.lowercased(),
              !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

// MARK: - Recorder

enum InsightsEvent: Sendable {
    case visit(URL)
    case search
    case tabOpened
    case tabClosed
    case tabSwitched
    case spaceSwitched
}

/// What the person is looking at right now, if they are browsing.
struct InsightsFocus {
    let site: String
    let space: UUID
}

/// Records browsing activity on this Mac only (never synced). Time counts
/// while Nous is the frontmost app, a browser window is key, a website is
/// showing and the Mac has had input in the last two minutes.
@MainActor
@Observable
final class BrowsingInsights {
    static let shared = BrowsingInsights()

    private(set) var log = InsightsLog()
    var isPaused: Bool {
        didSet {
            UserDefaults.standard.set(isPaused, forKey: Self.pausedKey)
            if isPaused { endStretch() }
        }
    }

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var focus: (() -> InsightsFocus?)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var lastActive: Date?
    @ObservationIgnored private var stretchSite: String?
    @ObservationIgnored private var stretchSeconds: Double = 0
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var lastSave = Date()
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    private static let pausedKey = "insights.paused"
    static let tickInterval: TimeInterval = 5
    static let idleLimit: TimeInterval = 120
    static let sessionGap: TimeInterval = 300
    static let minimumFocus: TimeInterval = 60

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nous Browser", isDirectory: true)
            .appendingPathComponent("insights.json")
        isPaused = UserDefaults.standard.bool(forKey: Self.pausedKey)
        if let data = try? Data(contentsOf: self.fileURL),
           let saved = try? JSONDecoder().decode(InsightsLog.self, from: data), saved.version == 1 {
            log = saved
        }
    }

    func start(focus: @escaping () -> InsightsFocus?) {
        self.focus = focus
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.endStretch()
                self?.save()
            }
        }
    }

    func note(_ event: InsightsEvent, at date: Date = Date()) {
        guard !isPaused else { return }
        update(date) { day in
            switch event {
            case .visit(let url):
                day.visits += 1
                if let site = InsightsLog.site(for: url) { day.sites[site, default: .init()].visits += 1 }
            case .search: day.searches += 1
            case .tabOpened: day.tabsOpened += 1
            case .tabClosed: day.tabsClosed += 1
            case .tabSwitched: day.tabSwitches += 1
            case .spaceSwitched: day.spaceSwitches += 1
            }
        }
    }

    /// Erases everything recorded so far.
    func clear() {
        endStretch()
        log = InsightsLog()
        lastActive = nil
        try? FileManager.default.removeItem(at: fileURL)
        dirty = false
    }

    // MARK: Active time

    private func tick(now: Date = Date()) {
        let elapsed = min(max(0, now.timeIntervalSince(lastTick ?? now)), Self.tickInterval * 2)
        lastTick = now
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                           eventType: CGEventType(rawValue: ~0)!)
        guard !isPaused, NSApp.isActive, idle < Self.idleLimit, let current = focus?() else {
            endStretch()
            saveIfDue(now)
            return
        }
        recordActive(seconds: elapsed, on: current, at: now)
        saveIfDue(now)
    }

    /// Adds active time; separated so tests can drive it.
    func recordActive(seconds: Double, on current: InsightsFocus, at now: Date) {
        guard seconds > 0 else { return }
        let newSession = lastActive.map { now.timeIntervalSince($0) > Self.sessionGap + Self.tickInterval } ?? true
        let hour = Calendar.current.component(.hour, from: now)
        if stretchSite != current.site {
            let switched = stretchSite != nil
            endStretch(at: now)
            stretchSite = current.site
            if switched { update(now) { $0.siteSwitches += 1 } }
        }
        stretchSeconds += seconds
        let stretch = stretchSeconds
        update(now) { day in
            if newSession { day.sessions += 1 }
            day.active += seconds
            day.hours[hour] += seconds
            day.sites[current.site, default: .init()].seconds += seconds
            day.spaces[current.space.uuidString, default: 0] += seconds
            if stretch > day.longestFocus {
                day.longestFocus = stretch
                day.longestFocusSite = current.site
            }
        }
        lastActive = now
    }

    private func endStretch(at date: Date = Date()) {
        if stretchSite != nil, stretchSeconds >= Self.minimumFocus {
            let seconds = stretchSeconds
            update(date) { day in
                day.focusStretches += 1
                day.focusSeconds += seconds
            }
        }
        stretchSite = nil
        stretchSeconds = 0
    }

    // MARK: Storage

    private func update(_ date: Date, _ change: (inout InsightsDay) -> Void) {
        let key = InsightsLog.key(for: date)
        var day = log.days[key] ?? InsightsDay()
        change(&day)
        log.days[key] = day
        dirty = true
    }

    private func saveIfDue(_ now: Date) {
        guard dirty, now.timeIntervalSince(lastSave) > 30 else { return }
        save()
    }

    private func save() {
        guard dirty else { return }
        log.prune(now: Date())
        lastSave = Date()
        dirty = false
        let snapshot = log
        let url = fileURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic])
        }
    }
}

// MARK: - Report

/// Everything the dashboard shows for one day, week or month.
nonisolated struct InsightsReport: Sendable {
    enum Scope: String, CaseIterable, Identifiable, Sendable {
        case day, week, month
        var id: String { rawValue }
        var component: Calendar.Component {
            switch self { case .day: .day; case .week: .weekOfYear; case .month: .month }
        }
    }

    struct Bucket: Identifiable, Sendable {
        let id: Int
        let start: Date
        let seconds: Double
        /// Later than now: drawn empty and left out of averages.
        let isFuture: Bool
    }

    struct SiteTotal: Identifiable, Sendable {
        var id: String { site }
        let site: String
        let seconds: Double
        let visits: Int
    }

    struct Counters: Equatable, Sendable {
        var visits = 0, searches = 0, tabsOpened = 0, tabsClosed = 0, tabSwitches = 0
        var spaceSwitches = 0, siteSwitches = 0, sessions = 0
        var focusStretches = 0, focusSeconds: Double = 0
    }

    let scope: Scope
    let interval: DateInterval
    let total: Double
    let previousTotal: Double
    /// Per active-ish day; nil for a single day.
    let dailyAverage: Double?
    let buckets: [Bucket]
    let sites: [SiteTotal]
    /// Seconds per space ID, largest first.
    let spaces: [(id: String, seconds: Double)]
    /// Rows start at the calendar's first weekday; 24 hours each.
    let heat: [[Double]]
    let counters: Counters
    let previousCounters: Counters
    /// The period includes now; comparisons cover the same stretch before.
    var isInProgress: Bool { interval.contains(Date()) }
    let longestFocus: Double
    let longestFocusSite: String?
    let peakHour: Int?
    let busiestDay: Date?
    let hasAnyData: Bool

    var averageFocus: Double? { counters.focusStretches > 0 ? counters.focusSeconds / Double(counters.focusStretches) : nil }
    /// Site changes per active hour: how fragmented attention was.
    var switchesPerHour: Double? { total >= 600 ? Double(counters.siteSwitches) / (total / 3600) : nil }

    static func interval(for scope: Scope, containing date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: scope.component, for: date) ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
    }

    static func make(log: InsightsLog, scope: Scope, anchor: Date, now: Date = Date(),
                     calendar: Calendar = .current) -> InsightsReport {
        let interval = interval(for: scope, containing: anchor, calendar: calendar)
        let previousAnchor = calendar.date(byAdding: scope.component, value: -1, to: interval.start) ?? interval.start
        let previous = Self.interval(for: scope, containing: previousAnchor, calendar: calendar)

        func days(in range: DateInterval) -> [(date: Date, day: InsightsDay?)] {
            var result: [(Date, InsightsDay?)] = []
            var date = range.start
            while date < range.end {
                result.append((date, log.day(date, calendar: calendar)))
                guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
                date = next
            }
            return result
        }
        func counters(_ list: [(date: Date, day: InsightsDay?)]) -> Counters {
            var c = Counters()
            for case let (_, day?) in list {
                c.visits += day.visits; c.searches += day.searches
                c.tabsOpened += day.tabsOpened; c.tabsClosed += day.tabsClosed
                c.tabSwitches += day.tabSwitches; c.spaceSwitches += day.spaceSwitches
                c.siteSwitches += day.siteSwitches; c.sessions += day.sessions
                c.focusStretches += day.focusStretches; c.focusSeconds += day.focusSeconds
            }
            return c
        }

        let current = days(in: interval)
        // A period still in progress is compared with the same stretch of
        // the one before (this week so far against last week to the same
        // weekday; today so far against yesterday up to this hour).
        let inProgress = interval.contains(now)
        let elapsedDays = inProgress ? current.filter { $0.date <= now }.count : current.count
        let before = Array(days(in: previous).prefix(elapsedDays))
        let total = current.reduce(0) { $0 + ($1.day?.active ?? 0) }
        var previousTotal = before.reduce(0) { $0 + ($1.day?.active ?? 0) }
        if scope == .day, inProgress, let yesterday = before.first?.day {
            let hour = calendar.component(.hour, from: now)
            previousTotal = yesterday.hours[0...hour].reduce(0, +)
        }

        // Buckets: hours of the day, or days of the week or month.
        var buckets: [Bucket] = []
        if scope == .day {
            let day = current.first?.day
            for hour in 0..<24 {
                let start = calendar.date(byAdding: .hour, value: hour, to: interval.start) ?? interval.start
                buckets.append(Bucket(id: hour, start: start, seconds: day?.hours[hour] ?? 0, isFuture: start > now))
            }
        } else {
            for (index, entry) in current.enumerated() {
                buckets.append(Bucket(id: index, start: entry.date, seconds: entry.day?.active ?? 0, isFuture: entry.date > now))
            }
        }

        // Daily average over the days that could have data: from the first
        // recorded day (or the period's start) up to today.
        var average: Double?
        if scope != .day {
            let firstKey = log.firstDayKey
            let counted = current.filter { entry in
                entry.date <= now && (firstKey.map { InsightsLog.key(for: entry.date, calendar: calendar) >= $0 } ?? false)
            }
            if !counted.isEmpty { average = total / Double(counted.count) }
        }

        var siteTotals: [String: InsightsDay.Site] = [:]
        var spaceTotals: [String: Double] = [:]
        var heat = Array(repeating: [Double](repeating: 0, count: 24), count: 7)
        var hourTotals = [Double](repeating: 0, count: 24)
        var longest: Double = 0
        var longestSite: String?
        var busiest: (Date, Double)?
        for case let (date, day?) in current {
            for (site, value) in day.sites {
                siteTotals[site, default: .init()].seconds += value.seconds
                siteTotals[site, default: .init()].visits += value.visits
            }
            for (space, seconds) in day.spaces { spaceTotals[space, default: 0] += seconds }
            let row = (calendar.component(.weekday, from: date) - calendar.firstWeekday + 7) % 7
            for hour in 0..<24 {
                heat[row][hour] += day.hours[hour]
                hourTotals[hour] += day.hours[hour]
            }
            if day.longestFocus > longest { longest = day.longestFocus; longestSite = day.longestFocusSite }
            if day.active > (busiest?.1 ?? 0) { busiest = (date, day.active) }
        }
        var sites: [SiteTotal] = []
        for (site, value) in siteTotals where value.seconds >= 1 || value.visits > 0 {
            sites.append(SiteTotal(site: site, seconds: value.seconds, visits: value.visits))
        }
        sites.sort { (a: SiteTotal, b: SiteTotal) -> Bool in
            a.seconds != b.seconds ? a.seconds > b.seconds : a.visits > b.visits
        }
        var spaces: [(id: String, seconds: Double)] = spaceTotals.map { (id: $0.key, seconds: $0.value) }
        spaces.sort { $0.seconds > $1.seconds }
        var peakHour: Int?
        var peakValue: Double = 60
        for (hour, value) in hourTotals.enumerated() where value >= peakValue {
            peakHour = hour
            peakValue = value
        }
        let currentCounters = counters(current)
        // Counts are kept per day, so today-so-far has no fair comparison.
        let previousCounters = scope == .day && inProgress ? Counters() : counters(before)
        let busiestDay: Date? = scope == .day ? nil : busiest?.0
        return InsightsReport(
            scope: scope, interval: interval, total: total, previousTotal: previousTotal, dailyAverage: average,
            buckets: buckets, sites: sites, spaces: spaces, heat: heat,
            counters: currentCounters, previousCounters: previousCounters,
            longestFocus: longest, longestFocusSite: longestSite,
            peakHour: peakHour, busiestDay: busiestDay, hasAnyData: !log.days.isEmpty)
    }
}
