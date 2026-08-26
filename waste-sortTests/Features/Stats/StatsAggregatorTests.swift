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
        #expect(snapshot.placements.allSatisfy { $0.total == 0 })
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
        let organicPlacement = snapshot.placements.first { $0.binID == "organic" }
        #expect(organicPlacement?.total == 2)
        #expect(organicPlacement?.correct == 1)
        #expect(organicPlacement?.misplaced == 1)
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

    @Test("weekly is Monday through Sunday")
    func weeklyStartsMonday() {
        let now = date(2026, 8, 21, 12) // Friday
        let sunday = date(2026, 8, 16, 12)
        let monday = date(2026, 8, 17, 12)
        let events = [
            event(at: sunday, classKey: "residual", zoneBinID: "residual", isCorrect: true),
            event(at: monday, classKey: "organic", zoneBinID: "organic", isCorrect: true)
        ]
        let snapshot = StatsAggregator.snapshot(
            events: events,
            period: .weekly,
            now: now,
            calendar: calendar
        )
        #expect(snapshot.generatedTotal == 1)
        #expect(snapshot.timeBuckets.count == 7)
        let firstWeekday = snapshot.timeBuckets.first.map {
            calendar.component(.weekday, from: $0.date)
        }
        #expect(firstWeekday == 2)
        #expect(snapshot.timeBuckets.first { calendar.isDate($0.date, inSameDayAs: monday) }?.generated == 1)
        #expect(snapshot.timeBuckets.first { calendar.isDate($0.date, inSameDayAs: sunday) } == nil)
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

    @Test("placements group by destination and split correct vs misplaced")
    func placementContamination() {
        let now = date(2026, 8, 21, 12)
        let events = [
            event(at: date(2026, 8, 21, 10), classKey: "organic", zoneBinID: "organic", isCorrect: true),
            event(at: date(2026, 8, 21, 11), classKey: "organic", zoneBinID: "residual", isCorrect: false)
        ]
        let snapshot = StatsAggregator.snapshot(
            events: events,
            period: .daily,
            now: now,
            calendar: calendar
        )
        let organic = snapshot.placements.first { $0.binID == "organic" }
        let residual = snapshot.placements.first { $0.binID == "residual" }
        #expect(organic?.total == 1)
        #expect(organic?.correct == 1)
        #expect(organic?.misplaced == 0)
        #expect(organic?.accuracyPercent == 100)
        #expect(residual?.total == 1)
        #expect(residual?.correct == 0)
        #expect(residual?.misplaced == 1)
        #expect(residual?.accuracyPercent == 0)
    }

    @Test("yearly September events land on the September slot")
    func yearlySeptemberSlot() {
        let now = date(2026, 8, 26, 15)
        let events = [
            event(at: date(2026, 8, 15, 12), classKey: "organic", zoneBinID: "organic", isCorrect: true),
            event(at: date(2026, 9, 15, 12), classKey: "organic", zoneBinID: "organic", isCorrect: true)
        ]
        let snapshot = StatsAggregator.snapshot(
            events: events,
            period: .yearly,
            now: now,
            calendar: calendar
        )
        let august = snapshot.timeBuckets.first { calendar.component(.month, from: $0.date) == 8 }
        let september = snapshot.timeBuckets.first { calendar.component(.month, from: $0.date) == 9 }
        #expect(august?.generated == 1)
        #expect(september?.generated == 1)
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
        let yearly = StatsMockData.snapshot(period: .yearly, now: now, calendar: calendar)
        #expect((130...160).contains(daily.count))
        #expect(weekly.count >= 500)
        #expect(monthly.count >= weekly.count)
        #expect(monthly.count >= 1_500)
        #expect(yearly.generatedTotal >= 20_000)
        #expect(yearly.timeBuckets.count == 12)
    }

    @Test("yearly months stay in the same ballpark including September")
    func yearlyMonthsStayEven() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 15))!
        let snapshot = StatsMockData.snapshot(period: .yearly, now: now, calendar: calendar)
        #expect(snapshot.timeBuckets.count == 12)
        let generated = snapshot.timeBuckets.map(\.generated)
        #expect(generated.allSatisfy { $0 >= 2_000 })
        let august = snapshot.timeBuckets.first { calendar.component(.month, from: $0.date) == 8 }?.generated ?? 0
        let september = snapshot.timeBuckets.first { calendar.component(.month, from: $0.date) == 9 }?.generated ?? 0
        #expect(august > 0)
        #expect(september > 0)
        let lower = min(august, september)
        let upper = max(august, september)
        #expect(upper - lower < upper / 4)
    }

    @Test("today mix is 80/42/20 with residual taking most mistakes")
    func todayMixIsConsistent() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 15))!
        let events = StatsMockData.events(now: now, calendar: calendar)
        let snapshot = StatsAggregator.snapshot(
            events: events,
            period: .daily,
            now: now,
            calendar: calendar
        )
        #expect(snapshot.generatedTotal == 142)
        let organicCount = snapshot.categoryCounts.first { $0.binID == BinGuide.organic.id }?.count
        let residualCount = snapshot.categoryCounts.first { $0.binID == BinGuide.residual.id }?.count
        let recyclableCount = snapshot.categoryCounts.first { $0.binID == BinGuide.cleanInorganic.id }?.count
        #expect(organicCount == StatsMockData.todayCategoryMix[BinGuide.organic.id])
        #expect(residualCount == StatsMockData.todayCategoryMix[BinGuide.residual.id])
        #expect(recyclableCount == StatsMockData.todayCategoryMix[BinGuide.cleanInorganic.id])
        #expect(snapshot.correctlyPlacedCount == 121)
        #expect(snapshot.correctlyPlacedPercent == 85)

        let organic = snapshot.placements.first { $0.binID == BinGuide.organic.id }
        let residual = snapshot.placements.first { $0.binID == BinGuide.residual.id }
        let recyclable = snapshot.placements.first { $0.binID == BinGuide.cleanInorganic.id }
        #expect(organic?.total == 74)
        #expect(organic?.correct == 72)
        #expect(residual?.total == 53)
        #expect(residual?.correct == 38)
        #expect(recyclable?.total == 15)
        #expect(recyclable?.correct == 11)
        #expect((residual?.misplaced ?? 0) > (organic?.misplaced ?? 0))
        #expect((organic?.total ?? 0) > (residual?.total ?? 0))
        #expect((residual?.total ?? 0) > (recyclable?.total ?? 0))
    }

    @Test("daily timeline hourly buckets sum to today's throws")
    func dailyTimelineMatchesToday() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 15))!
        let events = StatsMockData.events(now: now, calendar: calendar)
        let snapshot = StatsAggregator.snapshot(
            events: events,
            period: .daily,
            now: now,
            calendar: calendar
        )
        #expect(snapshot.timeBuckets.count == 13)
        let generated = snapshot.timeBuckets.reduce(0) { $0 + $1.generated }
        let misplaced = snapshot.timeBuckets.reduce(0) { $0 + $1.misplaced }
        #expect(generated == 142)
        #expect(misplaced == 21)
        let firstHour = snapshot.timeBuckets.first.map { calendar.component(.hour, from: $0.date) }
        let lastHour = snapshot.timeBuckets.last.map { calendar.component(.hour, from: $0.date) }
        #expect(firstHour == 7)
        #expect(lastHour == 19)
    }

    @Test("weekly monthly and yearly keep the organic-heavy mix and high accuracy")
    func longerPeriodsStayConsistent() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 15))!
        for period in [StatsPeriod.weekly, .monthly, .yearly] {
            let snapshot = StatsMockData.snapshot(
                period: period,
                now: now,
                calendar: calendar
            )
            let organic = snapshot.categoryCounts.first { $0.binID == BinGuide.organic.id }?.count ?? 0
            let residual = snapshot.categoryCounts.first { $0.binID == BinGuide.residual.id }?.count ?? 0
            let recyclable = snapshot.categoryCounts.first { $0.binID == BinGuide.cleanInorganic.id }?.count ?? 0
            #expect(organic > residual)
            #expect(residual > recyclable)
            #expect((80...90).contains(snapshot.correctlyPlacedPercent))
            let residualMisplaced = snapshot.placements.first { $0.binID == BinGuide.residual.id }?.misplaced ?? 0
            let organicMisplaced = snapshot.placements.first { $0.binID == BinGuide.organic.id }?.misplaced ?? 0
            #expect(residualMisplaced > organicMisplaced)
        }
    }
}

@Suite("StatsChartScale")
struct StatsChartScaleTests {
    @Test("small peaks use small steps")
    func smallPeak() {
        let axis = StatsChartScale.axis(peak: 16)
        #expect(axis.max >= 16)
        #expect(axis.step <= 5)
        #expect((3...8).contains(axis.ticks.count))
        #expect(axis.ticks.first == 0)
        #expect(axis.ticks.last == axis.max)
    }

    @Test("large peaks keep a handful of ticks")
    func largePeak() {
        let axis = StatsChartScale.axis(peak: 16_000)
        #expect(axis.max >= 16_000)
        #expect((3...8).contains(axis.ticks.count))
    }

    @Test("compacts thousands on labels")
    func compactLabels() {
        #expect(StatsChartScale.label(0) == "0")
        #expect(StatsChartScale.label(80) == "80")
        #expect(StatsChartScale.label(5_000) == "5k")
        #expect(StatsChartScale.label(20_000) == "20k")
    }
}
