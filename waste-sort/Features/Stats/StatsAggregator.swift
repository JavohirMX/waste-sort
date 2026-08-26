import Foundation

enum StatsPeriod: String, CaseIterable, Identifiable {
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"
    case yearly = "Yearly"

    var id: String { rawValue }
}

struct StatsCategoryCount: Identifiable, Equatable {
    let binID: String
    let count: Int
    var id: String { binID }
}

/// Throws into one destination bin, split by whether they belonged there.
struct StatsBinPlacement: Identifiable, Equatable {
    let binID: String
    let total: Int
    let correct: Int
    var id: String { binID }
    var misplaced: Int { total - correct }

    /// Rounded 0…100 share of throws into this bin that belonged there.
    var accuracyPercent: Int {
        guard total > 0 else { return 0 }
        return Int((Double(correct) / Double(total) * 100).rounded())
    }
}

struct StatsTimeBucket: Identifiable, Equatable {
    let date: Date
    let generated: Int
    let misplaced: Int
    var id: Date { date }
}

struct StatsSnapshot: Equatable {
    var generatedTotal: Int
    /// Deposits with `isCorrect == true` in the selected period.
    var correctlyPlacedCount: Int
    var categoryCounts: [StatsCategoryCount]
    var placements: [StatsBinPlacement]
    var timeBuckets: [StatsTimeBucket]
    var isEmpty: Bool { generatedTotal == 0 }

    /// Rounded 0…100 share of deposits placed in the correct bin.
    var correctlyPlacedPercent: Int {
        guard generatedTotal > 0 else { return 0 }
        return Int((Double(correctlyPlacedCount) / Double(generatedTotal) * 100).rounded())
    }
}

/// Pure aggregation over deposit events for the Stats page.
nonisolated enum StatsAggregator {
    /// Stats weeks are Monday–Sunday, independent of locale.
    static func mondayStarted(_ calendar: Calendar = .current) -> Calendar {
        var cal = calendar
        cal.firstWeekday = 2
        return cal
    }

    static func snapshot(
        events: [ZoneEventRecord],
        period: StatsPeriod,
        now: Date = Date(),
        calendar: Calendar = .current,
        binIDs: [String] = BinGuide.all.map(\.id)
    ) -> StatsSnapshot {
        let calendar = mondayStarted(calendar)
        let scoped = filter(events, period: period, now: now, calendar: calendar)
        let category = countsByClass(scoped, binIDs: binIDs)
        let placements = placementsByDestination(scoped, binIDs: binIDs)
        let buckets = timeBuckets(scoped, period: period, now: now, calendar: calendar)
        return StatsSnapshot(
            generatedTotal: scoped.count,
            correctlyPlacedCount: scoped.filter(\.isCorrect).count,
            categoryCounts: category,
            placements: placements,
            timeBuckets: buckets
        )
    }

    static func filter(
        _ events: [ZoneEventRecord],
        period: StatsPeriod,
        now: Date,
        calendar: Calendar
    ) -> [ZoneEventRecord] {
        let calendar = mondayStarted(calendar)
        guard let interval = periodInterval(period, now: now, calendar: calendar) else {
            return events
        }
        return events.filter { $0.timestamp >= interval.start && $0.timestamp < interval.end }
    }

    static func periodInterval(
        _ period: StatsPeriod,
        now: Date,
        calendar: Calendar
    ) -> DateInterval? {
        let calendar = mondayStarted(calendar)
        switch period {
        case .daily:
            return calendar.dateInterval(of: .day, for: now)
        case .weekly:
            return calendar.dateInterval(of: .weekOfYear, for: now)
        case .monthly:
            return calendar.dateInterval(of: .month, for: now)
        case .yearly:
            return calendar.dateInterval(of: .year, for: now)
        }
    }

    static func countsByClass(
        _ events: [ZoneEventRecord],
        binIDs: [String]
    ) -> [StatsCategoryCount] {
        let grouped = Dictionary(grouping: events) { BinGuide.info(for: $0.classKey).id }
        return binIDs.map { id in
            StatsCategoryCount(binID: id, count: grouped[id]?.count ?? 0)
        }
    }

    static func placementsByDestination(
        _ events: [ZoneEventRecord],
        binIDs: [String]
    ) -> [StatsBinPlacement] {
        let grouped = Dictionary(grouping: events) { BinGuide.info(for: $0.zoneBinID).id }
        return binIDs.map { id in
            let matching = grouped[id] ?? []
            return StatsBinPlacement(
                binID: id,
                total: matching.count,
                correct: matching.filter(\.isCorrect).count
            )
        }
    }

    static func timeBuckets(
        _ events: [ZoneEventRecord],
        period: StatsPeriod,
        now: Date,
        calendar: Calendar
    ) -> [StatsTimeBucket] {
        let calendar = mondayStarted(calendar)
        let component: Calendar.Component
        switch period {
        case .daily: component = .hour
        case .weekly, .monthly: component = .day
        case .yearly: component = .month
        }

        // Snap axis slots through the same interval start used to group events.
        // Adding months onto year.start can disagree with dateInterval(of: .month).
        let slots = axisSlots(period: period, now: now, calendar: calendar).map { slot in
            calendar.dateInterval(of: component, for: slot)?.start ?? slot
        }

        let grouped = Dictionary(grouping: events) { event -> Date in
            calendar.dateInterval(of: component, for: event.timestamp)?.start
                ?? calendar.startOfDay(for: event.timestamp)
        }

        return slots.map { slot in
            let matching = grouped[slot] ?? []
            return StatsTimeBucket(
                date: slot,
                generated: matching.count,
                misplaced: matching.filter { !$0.isCorrect }.count
            )
        }
    }

    /// X-axis slots. Daily uses 7am–7pm inclusive hours; other periods fill the calendar range.
    static func axisSlots(
        period: StatsPeriod,
        now: Date,
        calendar: Calendar
    ) -> [Date] {
        let calendar = mondayStarted(calendar)
        switch period {
        case .daily:
            let startOfDay = calendar.startOfDay(for: now)
            return (7...19).compactMap { hour in
                calendar.date(byAdding: .hour, value: hour, to: startOfDay)
            }
        case .weekly:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }
            return dayStarts(from: interval.start, until: interval.end, calendar: calendar)
        case .monthly:
            guard let interval = calendar.dateInterval(of: .month, for: now) else { return [] }
            return dayStarts(from: interval.start, until: interval.end, calendar: calendar)
        case .yearly:
            guard let interval = calendar.dateInterval(of: .year, for: now) else { return [] }
            var slots: [Date] = []
            var cursor = interval.start
            while cursor < interval.end {
                slots.append(cursor)
                guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
                cursor = next
            }
            return slots
        }
    }

    private static func dayStarts(from start: Date, until end: Date, calendar: Calendar) -> [Date] {
        var slots: [Date] = []
        var cursor = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        while cursor < endDay {
            slots.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return slots
    }
}
