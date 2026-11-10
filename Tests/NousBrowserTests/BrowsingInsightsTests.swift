import Foundation
import Testing
@testable import NousBrowser

@Suite("Browsing insights")
@MainActor
struct BrowsingInsightsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func recorder() -> BrowsingInsights {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("insights-\(UUID().uuidString).json")
        let insights = BrowsingInsights(fileURL: url)
        insights.isPaused = false
        return insights
    }

    @Test func sitesAreDomainsOnly() {
        #expect(InsightsLog.site(for: URL(string: "https://www.github.com/a/b?q=1")) == "github.com")
        #expect(InsightsLog.site(for: URL(string: "https://Docs.Example.com/x")) == "docs.example.com")
        #expect(InsightsLog.site(for: URL(string: "nous://library")) == nil)
        #expect(InsightsLog.site(for: nil) == nil)
    }

    @Test func activeTimeFillsHoursSitesSpacesAndFocus() {
        let insights = recorder()
        let space = UUID()
        var now = date(10, 9)
        // 20 minutes on one site, then 5 on another.
        for _ in 0..<240 { insights.recordActive(seconds: 5, on: .init(site: "github.com", space: space), at: now); now += 5 }
        for _ in 0..<60 { insights.recordActive(seconds: 5, on: .init(site: "figma.com", space: space), at: now); now += 5 }
        let day = insights.log.day(date(10, 9))!
        #expect(day.active == 1500)
        #expect(day.hours[9] == 1500)
        #expect(day.sites["github.com"]?.seconds == 1200)
        #expect(day.spaces[space.uuidString] == 1500)
        #expect(day.sessions == 1)
        #expect(day.siteSwitches == 1)
        #expect(day.longestFocus == 1200)
        #expect(day.longestFocusSite == "github.com")
        #expect(day.focusStretches == 1)
    }

    @Test func aLongBreakStartsANewSession() {
        let insights = recorder()
        let focus = InsightsFocus(site: "a.com", space: UUID())
        insights.recordActive(seconds: 5, on: focus, at: date(10, 9))
        insights.recordActive(seconds: 5, on: focus, at: date(10, 9, 2))
        insights.recordActive(seconds: 5, on: focus, at: date(10, 9, 20))
        #expect(insights.log.day(date(10, 9))?.sessions == 2)
    }

    @Test func eventsCountAndPausingStopsThem() {
        let insights = recorder()
        insights.note(.visit(URL(string: "https://www.apple.com/mac")!), at: date(10, 12))
        insights.note(.search, at: date(10, 12))
        insights.note(.tabOpened, at: date(10, 12))
        insights.isPaused = true
        insights.note(.search, at: date(10, 12))
        insights.isPaused = false
        let day = insights.log.day(date(10, 12))!
        #expect(day.visits == 1)
        #expect(day.sites["apple.com"]?.visits == 1)
        #expect(day.searches == 1)
        #expect(day.tabsOpened == 1)
    }

    @Test func weekReportTotalsAverageAndComparesWithTheWeekBefore() {
        var log = InsightsLog()
        var monday = InsightsDay(); monday.active = 3600; monday.hours[10] = 3600
        monday.sites = ["a.com": .init(seconds: 3000, visits: 4), "b.com": .init(seconds: 600, visits: 1)]
        var wednesday = InsightsDay(); wednesday.active = 1800; wednesday.hours[14] = 1800
        wednesday.sites = ["b.com": .init(seconds: 1800, visits: 2)]
        var lastWeek = InsightsDay(); lastWeek.active = 2700; lastWeek.hours[9] = 2700
        log.days[InsightsLog.key(for: date(9, 12), calendar: calendar)] = monday  // Monday 9 Nov
        log.days[InsightsLog.key(for: date(11, 12), calendar: calendar)] = wednesday
        log.days[InsightsLog.key(for: date(4, 12), calendar: calendar)] = lastWeek
        let report = InsightsReport.make(log: log, scope: .week, anchor: date(11, 12), now: date(11, 20), calendar: calendar)
        #expect(report.buckets.count == 7)
        #expect(report.total == 5400)
        #expect(report.previousTotal == 2700)
        // Monday to Wednesday: three days could have data.
        #expect(report.dailyAverage == 1800)
        #expect(report.sites.map(\.site) == ["a.com", "b.com"])
        #expect(report.sites[1].seconds == 2400)
        #expect(report.peakHour == 10)
        #expect(report.heat[0][10] == 3600)  // Monday row
        #expect(report.heat[2][14] == 1800)  // Wednesday row
        #expect(report.buckets[3].isFuture)
    }

    @Test func dayReportHasHourlyBuckets() {
        var log = InsightsLog()
        var day = InsightsDay(); day.active = 900; day.hours[22] = 900
        log.days[InsightsLog.key(for: date(10, 12), calendar: calendar)] = day
        let report = InsightsReport.make(log: log, scope: .day, anchor: date(10, 12), now: date(10, 23), calendar: calendar)
        #expect(report.buckets.count == 24)
        #expect(report.buckets[22].seconds == 900)
        #expect(report.dailyAverage == nil)
        #expect(report.busiestDay == nil)
    }

    @Test func durationsAndChanges() {
        #expect(InsightsFormat.change(150, from: 100)?.up == true)
        #expect(InsightsFormat.change(50, from: 100)?.up == false)
        #expect(InsightsFormat.change(100, from: 0) == nil)
    }
}

@Suite("Browsing insights comparison")
@MainActor
struct BrowsingInsightsComparisonTests {
    @Test func aWeekInProgressIsComparedWithTheSameDaysLastWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        func date(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
        }
        var log = InsightsLog()
        var day = InsightsDay(); day.active = 3600; day.visits = 10
        // Last week: Monday 2 to Sunday 8, one hour every day.
        for d in 2...8 { log.days[InsightsLog.key(for: date(d, 12), calendar: calendar)] = day }
        // This week: Monday 9 and Tuesday 10.
        for d in 9...10 { log.days[InsightsLog.key(for: date(d, 12), calendar: calendar)] = day }
        let report = InsightsReport.make(log: log, scope: .week, anchor: date(10, 12), now: date(10, 18), calendar: calendar)
        #expect(report.total == 7200)
        #expect(report.previousTotal == 7200)
        #expect(report.previousCounters.visits == 20)
    }
}
