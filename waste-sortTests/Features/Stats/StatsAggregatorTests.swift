import Foundation
import Testing

@testable import waste_sort

@Suite("StatsAggregator")
struct StatsAggregatorTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func event(
        at timestamp: Date,
        classKey: String,
        zoneBinID: String,
        isCorrect: Bool
    ) -> ZoneEventRecord {
        ZoneEventRecord(
            timestamp: timestamp,
            classKey: classKey,
            className: classKey,
            zoneID: UUID(),
            zoneName: "Zone",
            zoneBinID: zoneBinID,
            confidence: 0.9,
            isCorrect: isCorrect
        )
    }

    @Test("empty range yields zeros")
    func emptyRange() {
        let now = date(2026, 8, 21, 12)
        let snapshot = StatsAggregator.snapshot(events: [], period: .daily, now: now, calendar: calendar)
        #expect(snapshot.generatedTotal == 0)
        #expect(snapshot.isEmpty)
        // StatsCategoryCount.count is an Int payload, not a collection count;
        // isEmpty does not exist, so empty_count is a false positive here.
        #expect(snapshot.categoryCounts.allSatisfy { $0.count == 0 }) // swiftlint:disable:this empty_count
        #expect(snapshot.destinationCounts.allSatisfy { $0.count == 0 }) // swiftlint:disable:this empty_count
        #expect(snapshot.timeBuckets.count == 13)
        #expect(snapshot.timeBuckets.allSatisfy { $0.generated == 0 && $0.misplaced == 0 })
    }

    @Test("daily filters to calendar day and charts 7am–7pm")
    func dailyWindow() {
        let now = date(2026, 8, 21, 15)
        let events = [
            event(at: date(2026, 8, 21, 8), classKey: "organic", zoneBinID: "organic", isCorrect: true),
            event(at: date(2026, 8, 21, 16), classKey: "residual", zoneBinID: "organic", isCorrect: false),
            event(at: date(2026, 8, 20, 12), classKey: "organic", zoneBinID: "organic", isCorrect: true)
        ]
        let snapshot = StatsAggregator.snapshot(
            events: events,
            period: .daily,
            now: now,
            calendar: calendar
        )
        #expect(snapshot.generatedTotal == 2)
        #expect(snapshot.categoryCounts.first { $0.binID == "organic" }?.count == 1)
        #expect(snapshot.categoryCounts.first { $0.binID == "residual" }?.count == 1)
        #expect(snapshot.destinationCounts.first { $0.binID == "organic" }?.count == 2)
        #expect(snapshot.timeBuckets.count == 13)
        let eight = snapshot.timeBuckets.first {
            calendar.component(.hour, from: $0.date) == 8
        }
        let sixteen = snapshot.timeBuckets.first {
            calendar.component(.hour, from: $0.date) == 16
        }
        #expect(eight?.generated == 1)
        #expect(eight?.misplaced == 0)
        #expect(sixteen?.generated == 1)
        #expect(sixteen?.misplaced == 1)
    }

    @Test("weekly uses calendar week")
    func weeklyWindow() {
        let now = date(2026, 8, 21, 12) // Friday
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else {
            Issue.record("missing week")
            return
        }
        let inside = week.start.addingTimeInterval(3600)
        let outside = week.start.addingTimeInterval(-3600)
        let events = [
            event(at: inside, classKey: "organic", zoneBinID: "organic", isCorrect: true),
            event(at: outside, classKey: "residual", zoneBinID: "residual", isCorrect: true)
        ]
        let snapshot = StatsAggregator.snapshot(
            events: events,
            period: .weekly,
            now: now,
            calendar: calendar
        )
        #expect(snapshot.generatedTotal == 1)
        #expect(!snapshot.timeBuckets.isEmpty)
    }

    @Test("misplaced counts incorrect throws only")
    func misplacedDefinition() {
        let now = date(2026, 8, 21, 12)
        let events = [
            event(at: date(2026, 8, 21, 10), classKey: "organic", zoneBinID: "organic", isCorrect: true),
            event(at: date(2026, 8, 21, 11), classKey: "organic", zoneBinID: "residual", isCorrect: false),
            event(at: date(2026, 8, 21, 12), classKey: "residual", zoneBinID: "clean_inorganic", isCorrect: false)
        ]
        let snapshot = StatsAggregator.snapshot(
            events: events,
            period: .daily,
            now: now,
            calendar: calendar
        )
        let misplaced = snapshot.timeBuckets.reduce(0) { $0 + $1.misplaced }
        #expect(snapshot.generatedTotal == 3)
        #expect(misplaced == 2)
        #expect(snapshot.correctlyPlacedCount == 1)
        #expect(snapshot.correctlyPlacedPercent == 33)
    }

    @Test("empty correctly placed percent is zero")
    func correctlyPlacedEmpty() {
        let now = date(2026, 8, 21, 12)
        let snapshot = StatsAggregator.snapshot(events: [], period: .daily, now: now, calendar: calendar)
        #expect(snapshot.correctlyPlacedCount == 0)
        #expect(snapshot.correctlyPlacedPercent == 0)
    }
}

@Suite("StatsMockData")
struct StatsMockDataTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    @Test("today is near 142 and other periods are non-empty")
    func coverage() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 15))!
        let events = StatsMockData.events(now: now, calendar: calendar)
        let daily = StatsAggregator.filter(events, period: .daily, now: now, calendar: calendar)
        let weekly = StatsAggregator.filter(events, period: .weekly, now: now, calendar: calendar)
        let monthly = StatsAggregator.filter(events, period: .monthly, now: now, calendar: calendar)
        let yearly = StatsAggregator.filter(events, period: .yearly, now: now, calendar: calendar)
        #expect((130...160).contains(daily.count))
        #expect(weekly.count > daily.count)
        #expect(monthly.count >= weekly.count)
        #expect(yearly.count >= monthly.count)
    }

    @Test("bins filled mock overlay matches design")
    func binsFilledOverlay() {
        #expect(StatsMockData.binsFilled[BinGuide.organic.id] == 6)
        #expect(StatsMockData.binsFilled[BinGuide.residual.id] == 8)
        #expect(StatsMockData.binsFilled[BinGuide.cleanInorganic.id] == 3)
    }

    @Test("category bar mock overlay sums to 142")
    func categoryCountsOverlay() {
        #expect(StatsMockData.categoryCounts[BinGuide.organic.id] == 80)
        #expect(StatsMockData.categoryCounts[BinGuide.residual.id] == 42)
        #expect(StatsMockData.categoryCounts[BinGuide.cleanInorganic.id] == 20)
        let total = StatsMockData.categoryCounts.values.reduce(0, +)
        #expect(total == 142)
    }

    @Test("daily timeline buckets are angular vertices peaking near 190")
    func dailyTimelineShape() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 15))!
        let buckets = StatsMockData.dailyTimelineBuckets(now: now, calendar: calendar)
        #expect(buckets.count == 8)
        let peak = buckets.map(\.generated).max() ?? 0
        #expect(peak >= 185)
        #expect(buckets.first?.generated == 68)
        #expect(buckets.last?.generated == 140)
        #expect(calendar.component(.hour, from: buckets.last!.date) == 19)
    }
}
