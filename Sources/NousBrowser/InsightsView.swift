import AppKit
import SwiftUI

/// Library → Insights: where browsing time goes, when, and how focused it is,
/// in the manner of Screen Time. Everything is recorded on this Mac only.
struct InsightsView: View {
    let controller: BrowserController
    let width: CGFloat
    @State private var scope: InsightsReport.Scope = .week
    @State private var anchor = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var insights: BrowsingInsights { .shared }

    var body: some View {
        let report = InsightsReport.make(log: insights.log, scope: scope, anchor: anchor)
        VStack(alignment: .leading, spacing: 20) {
            periodBar(report)
            if !report.hasAnyData {
                InsightsCard { emptyState }
            } else {
                hero(report)
                tiles(report)
                adaptiveRow {
                    InsightsCard(title: L10n.string("Top Sites")) { InsightsTopSites(report: report) }
                } trailing: {
                    InsightsCard(title: L10n.string("Spaces")) { InsightsSpaces(report: report, spaces: controller.model.spaces) }
                }
                if scope != .day {
                    InsightsCard(title: L10n.string("When You Browse")) { InsightsHeatMap(report: report) }
                }
                adaptiveRow {
                    InsightsCard(title: L10n.string("Focus")) { focus(report) }
                } trailing: {
                    InsightsCard(title: L10n.string("Saved and Created")) { created(report) }
                }
            }
            privacyFooter
        }
        .animation(reduceMotion ? nil : BrowserMotion.spring, value: scope)
    }

    // MARK: Period

    private func periodBar(_ report: InsightsReport) -> some View {
        let next = Calendar.current.date(byAdding: scope.component, value: 1, to: report.interval.start) ?? Date()
        let isCurrent = report.interval.contains(Date())
        return HStack(spacing: 12) {
            Picker("", selection: $scope) {
                Text(L10n.string("Day")).tag(InsightsReport.Scope.day)
                Text(L10n.string("Week")).tag(InsightsReport.Scope.week)
                Text(L10n.string("Month")).tag(InsightsReport.Scope.month)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 8)
            if !isCurrent {
                Button(L10n.string("Today")) { anchor = Date() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            HStack(spacing: 2) {
                stepButton("chevron.left", L10n.string("Previous")) { step(-1) }
                Text(periodTitle(report))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .frame(minWidth: 120)
                stepButton("chevron.right", L10n.string("Next")) { step(1) }
                    .disabled(next > Date())
            }
        }
    }

    private func stepButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(label)
    }

    private func step(_ value: Int) {
        anchor = Calendar.current.date(byAdding: scope.component, value: value, to: anchor) ?? anchor
    }

    private func periodTitle(_ report: InsightsReport) -> String {
        let calendar = Calendar.current
        let start = report.interval.start
        switch scope {
        case .day:
            if calendar.isDateInToday(start) { return L10n.string("Today") }
            if calendar.isDateInYesterday(start) { return L10n.string("Yesterday") }
            return start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week:
            if report.interval.contains(Date()) { return L10n.string("This Week") }
            let end = report.interval.end.addingTimeInterval(-1)
            return start.formatted(.dateTime.month(.abbreviated).day()) + " – " + end.formatted(.dateTime.month(.abbreviated).day())
        case .month:
            if report.interval.contains(Date()) { return L10n.string("This Month") }
            return start.formatted(.dateTime.month(.wide).year())
        }
    }

    private func previousName(_ report: InsightsReport) -> String {
        if report.isInProgress {
            switch scope {
            case .day: return L10n.string("from this time yesterday")
            case .week: return L10n.string("from this point last week")
            case .month: return L10n.string("from this point last month")
            }
        }
        switch scope {
        case .day: return L10n.string("from the day before")
        case .week: return L10n.string("from the week before")
        case .month: return L10n.string("from the month before")
        }
    }

    // MARK: Hero

    private func hero(_ report: InsightsReport) -> some View {
        InsightsCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 28) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.string("Browsing Time")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Text(InsightsFormat.duration(report.total))
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    if let average = report.dailyAverage {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.string("Daily Average")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            Text(InsightsFormat.duration(average))
                                .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                        }
                    }
                    Spacer(minLength: 0)
                    if let delta = InsightsFormat.change(report.total, from: report.previousTotal) {
                        InsightsDelta(text: delta.text, up: delta.up, caption: previousName(report))
                    }
                }
                InsightsColumnChart(report: report)
                    .frame(height: 170)
                let highlights = highlights(report)
                if !highlights.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(highlights, id: \.text) { item in
                            Label(item.text, systemImage: item.symbol)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
            }
        }
    }

    private func highlights(_ report: InsightsReport) -> [(symbol: String, text: String)] {
        var items: [(String, String)] = []
        if report.total >= 600, let top = report.sites.first, top.seconds / report.total >= 0.15 {
            items.append(("globe", L10n.format("%@ took %@ of your browsing time.", top.site,
                                               (top.seconds / report.total).formatted(.percent.precision(.fractionLength(0))))))
        }
        if let hour = report.peakHour,
           let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) {
            items.append(("clock", L10n.format("You browse most around %@.", date.formatted(date: .omitted, time: .shortened))))
        }
        if let busiest = report.busiestDay {
            let name = scope == .week ? busiest.formatted(.dateTime.weekday(.wide))
                                      : busiest.formatted(.dateTime.month(.abbreviated).day())
            items.append(("calendar", L10n.format("%@ was your busiest day.", name)))
        }
        return items
    }

    // MARK: Tiles

    private func tiles(_ report: InsightsReport) -> some View {
        let c = report.counters, p = report.previousCounters
        let columns = width >= 700 ? 4 : 2
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: 14) {
            InsightsTile(label: L10n.string("Pages Visited"), value: c.visits, previous: p.visits, symbol: "doc.text")
            InsightsTile(label: L10n.string("Searches"), value: c.searches, previous: p.searches, symbol: "magnifyingglass")
            InsightsTile(label: L10n.string("Tabs Opened"), value: c.tabsOpened, previous: p.tabsOpened, symbol: "plus.square.on.square")
            InsightsTile(label: L10n.string("Sessions"), value: c.sessions, previous: p.sessions, symbol: "rectangle.stack")
        }
    }

    // MARK: Focus and creations

    private func focus(_ report: InsightsReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            InsightsFigure(label: L10n.string("Longest Focus"),
                           value: report.longestFocus >= 60 ? InsightsFormat.duration(report.longestFocus) : "—",
                           caption: report.longestFocus >= 60 ? report.longestFocusSite.map { L10n.format("on %@", $0) } : nil)
            InsightsFigure(label: L10n.string("Average Focus"),
                           value: report.averageFocus.map(InsightsFormat.duration) ?? "—",
                           caption: L10n.string("Time on one site before moving on"))
            InsightsFigure(label: L10n.string("Site Switches"),
                           value: report.switchesPerHour.map { L10n.format("%@ per hour", $0.formatted(.number.precision(.fractionLength(0)))) } ?? "—",
                           caption: L10n.format("%@ tab switches, %@ space switches",
                                                report.counters.tabSwitches.formatted(), report.counters.spaceSwitches.formatted()))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func created(_ report: InsightsReport) -> some View {
        let library = LibraryStore.shared
        let range = report.interval
        let bookmarks = library.bookmarks.filter { range.contains($0.created) }.count
        let downloads = library.downloads.filter { range.contains($0.date) && $0.state == .completed }
        let bytes = downloads.reduce(Int64(0)) { $0 + $1.size }
        let screenshots = library.captures.filter { $0.kind == .screenshot && range.contains($0.created) }.count
        let recordings = library.captures.filter { $0.kind == .recording && range.contains($0.created) }.count
        return VStack(alignment: .leading, spacing: 12) {
            InsightsCountRow(symbol: "star", label: L10n.string("Bookmarks Added"), value: bookmarks.formatted())
            InsightsCountRow(symbol: "arrow.down.circle", label: L10n.string("Downloads"),
                             value: downloads.isEmpty ? "0" : "\(downloads.count.formatted()) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
            InsightsCountRow(symbol: "camera.viewfinder", label: L10n.string("Screenshots"), value: screenshots.formatted())
            InsightsCountRow(symbol: "record.circle", label: L10n.string("Recordings"), value: recordings.formatted())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Layout helpers

    @ViewBuilder
    private func adaptiveRow<A: View, B: View>(@ViewBuilder leading: () -> A, @ViewBuilder trailing: () -> B) -> some View {
        if width >= 760 {
            HStack(alignment: .top, spacing: 16) {
                leading().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                trailing().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            leading()
            trailing()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text(L10n.string("Insights start now")).font(.system(size: 15, weight: .semibold))
            Text(L10n.string("As you browse, Nous notes how long you spend on each site, when you browse and how focused you are. Check back later today."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @State private var confirmClear = false

    private var privacyFooter: some View {
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 2)
            Text(L10n.string("Insights stay on this Mac and never sync. Nous keeps only each site’s domain, never page addresses or content. Time counts while Nous is in front and you are using your Mac."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Toggle(L10n.string("Record"), isOn: Binding(get: { !insights.isPaused }, set: { insights.isPaused = !$0 }))
                .toggleStyle(.switch).controlSize(.small)
            Button(L10n.string("Clear…")) { confirmClear = true }
                .controlSize(.small)
                .confirmationDialog(L10n.string("Clear all Insights?"), isPresented: $confirmClear) {
                    Button(L10n.string("Clear Insights"), role: .destructive) { BrowsingInsights.shared.clear() }
                } message: {
                    Text(L10n.string("Recorded browsing time and activity are removed from this Mac. History, bookmarks and downloads are kept."))
                }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

// MARK: - Formatting

enum InsightsFormat {
    private static let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    static func duration(_ seconds: Double) -> String {
        if seconds <= 0 { return formatter.string(from: 0) ?? "0m" }
        if seconds < 60 { return "<" + (formatter.string(from: 60) ?? "1m") }
        return formatter.string(from: (seconds / 60).rounded(.down) * 60) ?? ""
    }

    /// Signed percentage change; nil when there is nothing to compare with.
    static func change(_ value: Double, from previous: Double) -> (text: String, up: Bool)? {
        guard previous >= 60 || (previous > 0 && value < 60) else { return nil }
        let ratio = (value - previous) / previous
        guard ratio.isFinite else { return nil }
        return ((abs(ratio)).formatted(.percent.precision(.fractionLength(0))), ratio >= 0)
    }
}

// MARK: - Pieces

/// Same surface as the Library's cards.
private struct InsightsCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title { Text(title).font(.system(size: 15, weight: .semibold)) }
            content
        }
        .padding(18)
        // Fill the row, so side-by-side cards share one height.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LibraryStyle.card, in: RoundedRectangle(cornerRadius: LibraryStyle.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LibraryStyle.radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.04), radius: 10, y: 3)
    }
}

/// Change from the previous period, in neutral ink: more browsing is neither
/// good nor bad, so the arrow and words carry the direction, not a colour.
private struct InsightsDelta: View {
    let text: String
    let up: Bool
    let caption: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Label(text, systemImage: up ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .labelStyle(.titleAndIcon)
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary.opacity(0.8))
        .accessibilityElement(children: .combine)
    }
}

private struct InsightsTile: View {
    let label: String
    let value: Int
    let previous: Int
    let symbol: String

    var body: some View {
        InsightsCard {
            VStack(alignment: .leading, spacing: 6) {
                Label(label, systemImage: symbol)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                Text(value.formatted(.number.notation(.compactName)))
                    .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                if let change = InsightsFormat.change(Double(value), from: Double(previous)), previous > 0 {
                    Label(change.text, systemImage: change.up ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                } else {
                    Text(" ").font(.system(size: 11))
                }
            }
        }
    }
}

private struct InsightsFigure: View {
    let label: String
    let value: String
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            if let caption { Text(caption).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1) }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct InsightsCountRow: View {
    let symbol: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
            Text(label).font(.system(size: 13))
            Spacer(minLength: 8)
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Colours (validated reference palette)

enum InsightsPalette {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }

    /// The one-series accent (blue).
    static let accent = dynamic(0x2a78d6, 0x3987e5)

    /// Categorical slots in their fixed, colour-blind-checked order.
    static let categorical: [Color] = [
        dynamic(0x2a78d6, 0x3987e5), dynamic(0xeb6834, 0xd95926), dynamic(0x1baf7a, 0x199e70),
        dynamic(0xeda100, 0xc98500), dynamic(0xe87ba4, 0xd55181), dynamic(0x008300, 0x008300),
        dynamic(0x6250d6, 0x9085e9), dynamic(0xe34948, 0xe66767),
    ]
    static let other = dynamic(0xb8b7b1, 0x5c5b57)

    /// Sequential blue, from near-zero to most; dark mode brightens with value.
    static let heat: [Color] = [
        dynamic(0xcde2fb, 0x184f95), dynamic(0x9ec5f4, 0x1c5cab), dynamic(0x6da7ec, 0x2a78d6),
        dynamic(0x3987e5, 0x5598e7), dynamic(0x256abf, 0x9ec5f4),
    ]
}

// MARK: - Column chart

/// Browsing time per hour (day) or per day (week, month): one blue series,
/// thin columns rounded at the top, a hairline grid and the daily average.
private struct InsightsColumnChart: View {
    let report: InsightsReport
    @State private var hovered: Int?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let axisWidth: CGFloat = 34
            let labelHeight: CGFloat = 18
            let plotWidth = max(1, geometry.size.width - axisWidth)
            let plotHeight = max(1, geometry.size.height - labelHeight)
            let buckets = report.buckets
            let ticks = Self.ticks(for: max(buckets.map(\.seconds).max() ?? 0, report.scope == .day ? 0 : report.dailyAverage ?? 0))
            let top = ticks.last ?? 3600
            let slot = plotWidth / CGFloat(max(1, buckets.count))
            let barWidth = min(24, max(3, slot * 0.62))
            ZStack(alignment: .topLeading) {
                // Grid and y labels.
                ForEach(ticks, id: \.self) { tick in
                    let y = plotHeight * (1 - CGFloat(tick / top))
                    Rectangle().fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
                        .frame(width: plotWidth, height: 1)
                        .offset(y: y)
                    Text(InsightsFormat.duration(tick))
                        .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                        .fixedSize()
                        .offset(x: plotWidth + 6, y: y - 6)
                }
                // Columns.
                ForEach(buckets) { bucket in
                    let height = plotHeight * CGFloat(bucket.seconds / top)
                    let x = slot * CGFloat(bucket.id) + (slot - barWidth) / 2
                    if bucket.seconds > 0 {
                        UnevenRoundedRectangle(topLeadingRadius: min(4, barWidth / 2), topTrailingRadius: min(4, barWidth / 2),
                                               style: .continuous)
                            .fill(InsightsPalette.accent.opacity(hovered == nil || hovered == bucket.id ? 1 : 0.45))
                            .frame(width: barWidth, height: max(2, height))
                            .offset(x: x, y: plotHeight - max(2, height))
                    }
                    // Hover target: the whole slot, taller than the bar.
                    Rectangle().fill(Color.clear)
                        .frame(width: slot, height: plotHeight)
                        .contentShape(Rectangle())
                        .offset(x: slot * CGFloat(bucket.id))
                        .onHover { inside in
                            if inside { hovered = bucket.id } else if hovered == bucket.id { hovered = nil }
                        }
                        .accessibilityElement()
                        .accessibilityLabel(label(for: bucket))
                        .accessibilityValue(InsightsFormat.duration(bucket.seconds))
                    if let text = axisLabel(for: bucket) {
                        Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(width: max(slot, 30))
                            .offset(x: slot * CGFloat(bucket.id) + slot / 2 - max(slot, 30) / 2, y: plotHeight + 4)
                    }
                }
                // Daily average.
                if report.scope != .day, let average = report.dailyAverage, average > 0 {
                    let y = plotHeight * (1 - CGFloat(average / top))
                    Rectangle().fill(Color.primary.opacity(0.45)).frame(width: plotWidth, height: 1).offset(y: y)
                    Text(L10n.string("avg")).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .fixedSize()
                        .offset(x: plotWidth + 6, y: y - 6)
                }
                // Tooltip.
                if let hovered, let bucket = buckets.first(where: { $0.id == hovered }) {
                    let height = plotHeight * CGFloat(bucket.seconds / top)
                    let center = slot * CGFloat(bucket.id) + slot / 2
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label(for: bucket)).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(InsightsFormat.duration(bucket.seconds)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .fixedSize()
                    .alignmentGuide(.leading) { $0.width / 2 }
                    .offset(x: min(max(center, 70), plotWidth - 70), y: max(0, plotHeight - height - 52))
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: hovered)
        }
    }

    private func label(for bucket: InsightsReport.Bucket) -> String {
        switch report.scope {
        case .day:
            let end = bucket.start.addingTimeInterval(3600)
            return bucket.start.formatted(.dateTime.hour()) + " – " + end.formatted(.dateTime.hour())
        case .week: return bucket.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        case .month: return bucket.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
    }

    private func axisLabel(for bucket: InsightsReport.Bucket) -> String? {
        switch report.scope {
        case .day: return bucket.id % 6 == 0 ? bucket.start.formatted(.dateTime.hour()) : nil
        case .week: return bucket.start.formatted(.dateTime.weekday(.abbreviated))
        case .month:
            let day = Calendar.current.component(.day, from: bucket.start)
            return [1, 8, 15, 22, 29].contains(day) ? "\(day)" : nil
        }
    }

    /// Clean steps: minutes for short spans, hours otherwise.
    static func ticks(for maximum: Double) -> [Double] {
        let candidates: [Double] = [5, 10, 15, 30, 60, 120, 180, 240, 360, 480, 720].map { $0 * 60 }
        let target = max(maximum, 60) / 3
        let step = candidates.first { $0 >= target } ?? 720 * 60
        return [step, step * 2, step * 3]
    }
}

// MARK: - Top sites

private struct InsightsTopSites: View {
    let report: InsightsReport
    static let shown = 6

    var body: some View {
        let sites = report.sites.filter { $0.seconds >= 60 }
        let top = sites.first?.seconds ?? 1
        if sites.isEmpty {
            Text(L10n.string("Sites you spend time on appear here.")).font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(sites.prefix(Self.shown)) { site in
                    InsightsSiteRow(site: site, fraction: site.seconds / top)
                }
                let rest = sites.dropFirst(Self.shown)
                if !rest.isEmpty {
                    let seconds = rest.reduce(0) { $0 + $1.seconds }
                    HStack {
                        Text(L10n.format("%@ other sites", rest.count.formatted()))
                        Spacer()
                        Text(InsightsFormat.duration(seconds)).monospacedDigit()
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct InsightsSiteRow: View {
    let site: InsightsReport.SiteTotal
    let fraction: Double
    @State private var favicon: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Group {
                    if let favicon { Image(nsImage: favicon).resizable().interpolation(.high) }
                    else { Image(systemName: site.site == "file" ? "doc" : "globe").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                .frame(width: 16, height: 16)
                Text(site.site == "file" ? L10n.string("Local Files") : site.site)
                    .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if site.visits > 0 {
                    Text(L10n.format("%@ visits", site.visits.formatted())).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Text(InsightsFormat.duration(site.seconds)).font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
            GeometryReader { geometry in
                Capsule().fill(InsightsPalette.accent)
                    .frame(width: max(4, geometry.size.width * fraction), height: 4)
            }
            .frame(height: 4)
            .padding(.leading, 24)
        }
        .accessibilityElement(children: .combine)
        .task(id: site.site) {
            guard site.site != "file", let url = URL(string: "https://\(site.site)") else { return }
            favicon = FaviconStore.shared.cachedImage(for: url)
            if favicon == nil { favicon = await FaviconStore.shared.image(for: url) }
        }
    }
}

// MARK: - Spaces

/// One whole split into its spaces: a tall segmented bar, then a legend that
/// names each part with its time and share. Colours follow the space's place
/// in the sidebar, so they never change with the period.
private struct InsightsSpaces: View {
    let report: InsightsReport
    let spaces: [BrowserSpaceRecord]

    private struct Part: Identifiable {
        let id: String
        let name: String
        let icon: String
        let seconds: Double
        let color: Color
        let dark: Bool
    }

    /// Slots whose fill needs near-black text: aqua, yellow, magenta.
    private static let lightFills: Set<Int> = [2, 3, 4]

    private var parts: [Part] {
        var result: [Part] = []
        var other: Double = 0
        for entry in report.spaces where entry.seconds >= 1 {
            if let index = spaces.firstIndex(where: { $0.id.uuidString == entry.id }), index < InsightsPalette.categorical.count {
                let space = spaces[index]
                result.append(Part(id: entry.id, name: space.name, icon: space.icon, seconds: entry.seconds,
                                   color: InsightsPalette.categorical[index], dark: Self.lightFills.contains(index)))
            } else {
                other += entry.seconds
            }
        }
        if other >= 1 {
            result.append(Part(id: "other", name: L10n.string("Other"), icon: "ellipsis", seconds: other,
                               color: InsightsPalette.other, dark: true))
        }
        return result
    }

    var body: some View {
        let parts = parts
        let total = parts.reduce(0) { $0 + $1.seconds }
        if total < 60 {
            Text(L10n.string("Time in each space appears here.")).font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                GeometryReader { geometry in
                    let gap: CGFloat = 2
                    let usable = geometry.size.width - gap * CGFloat(max(0, parts.count - 1))
                    HStack(spacing: gap) {
                        ForEach(parts) { part in
                            let share = part.seconds / total
                            let width = max(2, usable * share)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(part.color)
                                .frame(width: width)
                                .overlay(alignment: .leading) {
                                    let text = share.formatted(.percent.precision(.fractionLength(0)))
                                    if width >= 42 {
                                        Text(text).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                            .foregroundStyle(part.dark ? Color(white: 0.1) : .white)
                                            .padding(.leading, 7)
                                    }
                                }
                                .help("\(part.name) · \(InsightsFormat.duration(part.seconds)) · \(share.formatted(.percent.precision(.fractionLength(0))))")
                        }
                    }
                }
                .frame(height: 28)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(parts) { part in
                        HStack(spacing: 8) {
                            Circle().fill(part.color).frame(width: 8, height: 8)
                            Group {
                                if part.icon.unicodeScalars.first?.properties.isEmojiPresentation == true || NSImage(systemSymbolName: part.icon, accessibilityDescription: nil) == nil {
                                    Text(part.icon).font(.system(size: 11))
                                } else {
                                    Image(systemName: part.icon).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 16)
                            Text(part.name).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(InsightsFormat.duration(part.seconds)).font(.system(size: 13, weight: .medium)).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

// MARK: - Heat map

/// Browsing time by weekday and hour across the period: one blue ramp, light
/// for a little, dark for a lot (brighter for a lot in dark mode).
private struct InsightsHeatMap: View {
    let report: InsightsReport
    @State private var hovered: (row: Int, hour: Int)?

    private var weekdayNames: [String] {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    static func level(_ value: Double, maximum: Double) -> Int? {
        guard value >= 30, maximum > 0 else { return nil }
        return min(4, Int((value / maximum * 5).rounded(.up)) - 1)
    }

    var body: some View {
        let maximum = report.heat.flatMap { $0 }.max() ?? 0
        let names = weekdayNames
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                let labelWidth: CGFloat = 34
                let gap: CGFloat = 2
                let cell = max(4, (geometry.size.width - labelWidth - gap * 23) / 24)
                let cellHeight = min(cell, 18)
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(0..<7, id: \.self) { row in
                        HStack(spacing: gap) {
                            Text(names[row]).font(.system(size: 10)).foregroundStyle(.secondary)
                                .frame(width: labelWidth - 4, alignment: .leading)
                            ForEach(0..<24, id: \.self) { hour in
                                let value = report.heat[row][hour]
                                let level = Self.level(value, maximum: maximum)
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(level.map { InsightsPalette.heat[$0] } ?? Color.primary.opacity(0.05))
                                    .frame(width: cell, height: cellHeight)
                                    .overlay {
                                        if hovered?.row == row && hovered?.hour == hour {
                                            RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.primary.opacity(0.6), lineWidth: 1)
                                        }
                                    }
                                    .onHover { inside in
                                        if inside { hovered = (row, hour) }
                                        else if hovered?.row == row && hovered?.hour == hour { hovered = nil }
                                    }
                                    .help("\(names[row]) \(hourName(hour)) · \(InsightsFormat.duration(value))")
                                    .accessibilityLabel("\(names[row]) \(hourName(hour))")
                                    .accessibilityValue(InsightsFormat.duration(value))
                            }
                        }
                    }
                    HStack(spacing: 0) {
                        Color.clear.frame(width: labelWidth - 4 + gap)
                        ForEach([0, 6, 12, 18], id: \.self) { hour in
                            Text(hourName(hour)).font(.system(size: 10)).foregroundStyle(.tertiary)
                                .frame(width: (cell + gap) * 6, alignment: .leading)
                        }
                    }
                }
            }
            .frame(height: 7 * 18 + 6 * 2 + 18)
            HStack(spacing: 6) {
                if let hovered {
                    Text("\(names[hovered.row]) \(hourName(hovered.hour)) · \(InsightsFormat.duration(report.heat[hovered.row][hovered.hour]))")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
                Spacer()
                Text(L10n.string("Less")).font(.system(size: 10)).foregroundStyle(.tertiary)
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.05)).frame(width: 10, height: 10)
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2).fill(InsightsPalette.heat[index]).frame(width: 10, height: 10)
                }
                Text(L10n.string("More")).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private func hourName(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}
