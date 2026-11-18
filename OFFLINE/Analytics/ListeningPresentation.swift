import Foundation

/// Text formatting for listening values. Pure, so it is unit tested.
enum ListeningFormat {
    /// "128h 42m", "42m", "<1m" or "0m".
    static func duration(_ ms: Int64) -> String {
        guard ms > 0 else { return "0m" }
        let minutes = ms / 60_000
        guard minutes > 0 else { return "<1m" }
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// Spoken form for VoiceOver: "128 hours, 42 minutes".
    static func spokenDuration(_ ms: Int64) -> String {
        guard ms >= 60_000 else { return ms > 0 ? "less than a minute" : "no listening" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .full
        return formatter.string(from: TimeInterval(ms / 60_000 * 60)) ?? duration(ms)
    }

    static func plays(_ count: Int) -> String { count == 1 ? "1 play" : "\(count.formatted()) plays" }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}

/// Chart buckets built from the real per-day totals. Ranges are filled with zero days so
/// gaps are honest; All Time switches to weekly or monthly buckets instead of drawing
/// thousands of daily bars.
enum ListeningChartModel {
    enum Granularity: Equatable { case day, week, month }

    struct Bucket: Identifiable, Equatable {
        let start: Date
        let listenedMs: Int64
        var id: Date { start }
        var minutes: Double { Double(listenedMs) / 60_000 }
    }

    static func granularity(for range: ListeningRange, spanDays: Int) -> Granularity {
        guard range == .allTime else { return .day }
        if spanDays <= 31 { return .day }
        if spanDays <= 26 * 7 { return .week }
        return .month
    }

    static func buckets(for summary: ListeningSummary, now: Date = Date(), calendar: Calendar = .current) -> (Granularity, [Bucket]) {
        let keys = ListeningDayKey(calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let first = firstDay(summary, today: today, calendar: calendar)
        let span = (calendar.dateComponents([.day], from: first, to: today).day ?? 0) + 1
        let granularity = Self.granularity(for: summary.range, spanDays: span)
        var totals: [Date: Int64] = [:]
        for day in summary.days {
            guard let date = keys.date(for: day.day), let start = bucketStart(date, granularity, calendar) else { continue }
            totals[start, default: 0] += day.listenedMs
        }
        var result: [Bucket] = []
        guard var cursor = bucketStart(first, granularity, calendar), let last = bucketStart(today, granularity, calendar) else { return (granularity, []) }
        while cursor <= last {
            result.append(Bucket(start: cursor, listenedMs: totals[cursor] ?? 0))
            guard let next = calendar.date(byAdding: component(granularity), value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return (granularity, result)
    }

    /// The first calendar day the chart covers: the range start, or for All Time the earlier
    /// of the first listening day and the day accurate tracking began.
    static func firstDay(_ summary: ListeningSummary, today: Date, calendar: Calendar) -> Date {
        if let count = summary.range.dayCount { return calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today }
        let earliestData = summary.days.first.flatMap { ListeningDayKey(calendar: calendar).date(for: $0.day) }
        let candidates = [earliestData, summary.trackingStartedAt.map { calendar.startOfDay(for: $0) }].compactMap { $0 }
        return min(candidates.min() ?? today, today)
    }

    static func component(_ granularity: Granularity) -> Calendar.Component {
        switch granularity { case .day: return .day; case .week: return .weekOfYear; case .month: return .month }
    }

    static func bucketStart(_ date: Date, _ granularity: Granularity, _ calendar: Calendar) -> Date? {
        switch granularity {
        case .day: return calendar.startOfDay(for: date)
        case .week: return calendar.dateInterval(of: .weekOfYear, for: date)?.start
        case .month: return calendar.dateInterval(of: .month, for: date)?.start
        }
    }

    /// "Tuesday", "Tue 12 Nov", "Week of 4 Nov" or "November 2026".
    static func label(for start: Date, granularity: Granularity, range: ListeningRange) -> String {
        switch granularity {
        case .day where range == .last7: return start.formatted(.dateTime.weekday(.wide))
        case .day: return start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .week: return "Week of " + start.formatted(.dateTime.day().month(.abbreviated))
        case .month: return start.formatted(.dateTime.month(.wide).year())
        }
    }

    /// Days in the range with any listening, and the number of days in the range.
    static func activeDays(_ summary: ListeningSummary, now: Date = Date(), calendar: Calendar = .current) -> (active: Int, total: Int) {
        let active = summary.days.filter { $0.listenedMs > 0 }.count
        if let count = summary.range.dayCount { return (active, count) }
        let today = calendar.startOfDay(for: now)
        let first = firstDay(summary, today: today, calendar: calendar)
        let span = (calendar.dateComponents([.day], from: first, to: today).day ?? 0) + 1
        return (active, max(span, active, 1))
    }
}
