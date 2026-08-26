import Foundation

/// Canned deposit events for previewing Stats. Never written to History JSONL.
nonisolated enum StatsMockData {
    /// Today's generated mix: organic-heavy campus kiosk, 142 throws.
    static let todayCategoryMix: [String: Int] = [
        BinGuide.organic.id: 80,
        BinGuide.residual.id: 42,
        BinGuide.cleanInorganic.id: 20
    ]

    /// Stable UUIDs so snapshots stay comparable in tests.
    private static let organicZone = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private static let residualZone = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private static let recyclableZone = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    private static let cacheLock = NSLock()
    private static var throughMonthCache: [Date: [ZoneEventRecord]] = [:]
    private static var snapshotCache: [SnapshotCacheKey: StatsSnapshot] = [:]
    private static let mockEventID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!

    private struct SnapshotCacheKey: Hashable {
        let day: Date
        let period: StatsPeriod
        let binIDs: [String]
    }

    static func snapshot(
        period: StatsPeriod,
        now: Date = Date(),
        calendar: Calendar = .current,
        binIDs: [String] = BinGuide.all.map(\.id)
    ) -> StatsSnapshot {
        let calendar = StatsAggregator.mondayStarted(calendar)
        let key = SnapshotCacheKey(day: calendar.startOfDay(for: now), period: period, binIDs: binIDs)
        cacheLock.lock()
        if let cached = snapshotCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let result: StatsSnapshot
        if period == .yearly {
            result = yearlySnapshot(now: now, calendar: calendar, binIDs: binIDs)
        } else {
            result = StatsAggregator.snapshot(
                events: events(now: now, calendar: calendar),
                period: period,
                now: now,
                calendar: calendar,
                binIDs: binIDs
            )
        }
        cacheLock.lock()
        snapshotCache[key] = result
        cacheLock.unlock()
        return result
    }

    static func events(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ZoneEventRecord] {
        let calendar = StatsAggregator.mondayStarted(calendar)
        let day = calendar.startOfDay(for: now)
        cacheLock.lock()
        if let cached = throughMonthCache[day] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        var records: [ZoneEventRecord] = []
        records.append(contentsOf: todayEvents(now: now, calendar: calendar))
        records.append(contentsOf: weekExtras(now: now, calendar: calendar))
        records.append(contentsOf: monthExtras(now: now, calendar: calendar))
        cacheLock.lock()
        throughMonthCache[day] = records
        cacheLock.unlock()
        return records
    }

    /// 142 throws: 80 / 42 / 20 by class, ~85% correct. Residual absorbs most mistakes.
    private static let todayThrows: [MockThrow] = deterministicallyShuffled(
        scaledMix(count: 142),
        salt: 0xC0FFEE
    )

    /// ~142 throws today, mixed through the day rather than one category at a time.
    private static func todayEvents(now: Date, calendar: Calendar) -> [ZoneEventRecord] {
        scatter(todayThrows, on: calendar.startOfDay(for: now), calendar: calendar, seed: 0)
    }

    private static func weekExtras(now: Date, calendar: Calendar) -> [ZoneEventRecord] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }
        return days(
            from: week.start,
            until: week.end,
            calendar: calendar,
            seedBase: 1_000
        ) { day in
            !calendar.isDate(day, inSameDayAs: now)
        }
    }

    private static func monthExtras(now: Date, calendar: Calendar) -> [ZoneEventRecord] {
        guard let month = calendar.dateInterval(of: .month, for: now),
              let week = calendar.dateInterval(of: .weekOfYear, for: now)
        else { return [] }
        return days(
            from: month.start,
            until: month.end,
            calendar: calendar,
            seedBase: 2_000
        ) { day in
            day < week.start || day >= week.end
        }
    }

    private static func days(
        from start: Date,
        until end: Date,
        calendar: Calendar,
        seedBase: Int,
        include: (Date) -> Bool
    ) -> [ZoneEventRecord] {
        var records: [ZoneEventRecord] = []
        var cursor = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        var offset = 0
        while cursor < endDay {
            if include(cursor) {
                records.append(
                    contentsOf: eventsOnDay(cursor, calendar: calendar, seedBase: seedBase + offset)
                )
            }
            offset += 1
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return records
    }

    private static func eventsOnDay(
        _ day: Date,
        calendar: Calendar,
        seedBase: Int
    ) -> [ZoneEventRecord] {
        let count = throwCount(on: day, calendar: calendar, salt: seedBase)
        let items = deterministicallyShuffled(scaledMix(count: count), salt: UInt64(truncatingIfNeeded: seedBase))
        return scatter(items, on: calendar.startOfDay(for: day), calendar: calendar, seed: seedBase)
    }

    /// Weekdays ~124–142; weekends ~42–54.
    private static func throwCount(on day: Date, calendar: Calendar, salt: Int) -> Int {
        let weekday = calendar.component(.weekday, from: day)
        let jitter = abs(salt) % 13
        if weekday == 1 || weekday == 7 {
            return 42 + jitter
        }
        return 124 + (abs(salt) % 19)
    }

    private static func scatter(
        _ items: [MockThrow],
        on startOfDay: Date,
        calendar: Calendar,
        seed: Int
    ) -> [ZoneEventRecord] {
        let hours = allocate(items.count, weights: Self.hourProfile)
        var records: [ZoneEventRecord] = []
        records.reserveCapacity(items.count)
        var index = 0
        var localSeed = seed
        for (hour, count) in hours {
            guard let hourStart = calendar.date(byAdding: .hour, value: hour, to: startOfDay) else {
                continue
            }
            for i in 0..<count {
                guard index < items.count else { return records }
                let minutes = (i * 57) % 60
                let seconds = (i * 13) % 60
                guard let stamp = calendar.date(
                    byAdding: .second,
                    value: minutes * 60 + seconds,
                    to: hourStart
                ) else { continue }
                let item = items[index]
                records.append(
                    makeEvent(
                        at: stamp,
                        seed: localSeed,
                        classKey: item.classKey,
                        destination: item.destination
                    )
                )
                index += 1
                localSeed += 1
            }
        }
        return records
    }

    private static let hourProfile: [(hour: Int, weight: Int)] = [
        (7, 8), (8, 9), (9, 10), (10, 8), (11, 9), (12, 12),
        (13, 13), (14, 14), (15, 15), (16, 16), (17, 14), (18, 9), (19, 5)
    ]

    private static let mixBuckets: [MixBucket] = {
        let organic = BinGuide.organic.id
        let residual = BinGuide.residual.id
        let recyclable = BinGuide.cleanInorganic.id
        return [
            MixBucket(classKey: organic, destination: organic, weight: 72),
            MixBucket(classKey: organic, destination: residual, weight: 8),
            MixBucket(classKey: residual, destination: residual, weight: 38),
            MixBucket(classKey: residual, destination: recyclable, weight: 4),
            MixBucket(classKey: recyclable, destination: recyclable, weight: 11),
            MixBucket(classKey: recyclable, destination: residual, weight: 7),
            MixBucket(classKey: recyclable, destination: organic, weight: 2)
        ]
    }()

    private static func scaledMix(count: Int) -> [MockThrow] {
        guard count > 0 else { return [] }
        let sizes = allocate(count, weights: mixBuckets.map(\.weight))
        var items: [MockThrow] = []
        items.reserveCapacity(count)
        for (bucket, size) in zip(mixBuckets, sizes) {
            items.append(
                contentsOf: repeatElement(
                    MockThrow(classKey: bucket.classKey, destination: bucket.destination),
                    count: size
                )
            )
        }
        return items
    }

    /// Largest-remainder allocation. `weights` is `(key, weight)` or hour/profile pairs.
    private static func allocate(_ count: Int, weights: [(hour: Int, weight: Int)]) -> [(hour: Int, weight: Int)] {
        let sizes = allocate(count, weights: weights.map(\.weight))
        return zip(weights.map(\.hour), sizes).map { (hour: $0, weight: $1) }
    }

    private static func allocate(_ count: Int, weights: [Int]) -> [Int] {
        let weightSum = max(weights.reduce(0, +), 1)
        var sizes = weights.map { weight in
            Int((Double(weight) / Double(weightSum) * Double(count)).rounded(.down))
        }
        var leftover = count - sizes.reduce(0, +)
        let order = weights.indices.sorted { left, right in
            let leftFrac = fractional(weights[left], count: count, weightSum: weightSum)
            let rightFrac = fractional(weights[right], count: count, weightSum: weightSum)
            return leftFrac > rightFrac
        }
        var cursor = 0
        while leftover > 0, !order.isEmpty {
            sizes[order[cursor % order.count]] += 1
            leftover -= 1
            cursor += 1
        }
        return sizes
    }

    private static func fractional(_ weight: Int, count: Int, weightSum: Int) -> Double {
        let raw = Double(weight) / Double(weightSum) * Double(count)
        return raw - raw.rounded(.down)
    }

    private static func makeEvent(
        at date: Date,
        seed: Int,
        classKey: String,
        destination: String
    ) -> ZoneEventRecord {
        let isCorrect = BinGuide.isAcceptedDeposit(classKey: classKey, zoneBinID: destination)
        let zoneID: UUID
        switch destination {
        case BinGuide.organic.id: zoneID = organicZone
        case BinGuide.residual.id: zoneID = residualZone
        default: zoneID = recyclableZone
        }
        return ZoneEventRecord(
            id: mockEventID,
            timestamp: date,
            classKey: classKey,
            className: classKey,
            zoneID: zoneID,
            zoneName: BinGuide.bin(id: destination).displayName.capitalized,
            zoneBinID: destination,
            confidence: 0.7 + Double(abs(seed) % 20) / 100,
            isCorrect: isCorrect,
            viaTrajectory: false,
            binWasOpen: true
        )
    }

    private struct MockThrow {
        let classKey: String
        let destination: String
    }

    private struct MixBucket {
        let classKey: String
        let destination: String
        let weight: Int
    }

    private static func deterministicallyShuffled(_ items: [MockThrow], salt: UInt64) -> [MockThrow] {
        var pairs = items
        var state = salt == 0 ? 1 : salt
        var index = pairs.count - 1
        while index >= 1 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let other = Int(state % UInt64(index + 1))
            pairs.swapAt(index, other)
            index -= 1
        }
        return pairs
    }
}

extension StatsMockData {
    private struct MonthSummary {
        var generated: Int
        var correct: Int
        var classCounts: [String: Int]
        var destTotals: [String: Int]
        var destCorrect: [String: Int]
    }

    /// Month totals, not tens of thousands of events. Future months stay filled
    /// so the yearly line does not drop off after the current month.
    fileprivate static func yearlySnapshot(
        now: Date,
        calendar: Calendar,
        binIDs: [String]
    ) -> StatsSnapshot {
        let slots = StatsAggregator.axisSlots(period: .yearly, now: now, calendar: calendar)
        var classCounts: [String: Int] = [:]
        var destTotals: [String: Int] = [:]
        var destCorrect: [String: Int] = [:]
        var generatedTotal = 0
        var correctTotal = 0
        var buckets: [StatsTimeBucket] = []
        buckets.reserveCapacity(slots.count)

        for (monthIndex, monthStart) in slots.enumerated() {
            let slotDate = calendar.dateInterval(of: .month, for: monthStart)?.start ?? monthStart
            let summary = monthSummary(monthStart: slotDate, monthIndex: monthIndex, calendar: calendar)
            generatedTotal += summary.generated
            correctTotal += summary.correct
            for (id, count) in summary.classCounts { classCounts[id, default: 0] += count }
            for (id, count) in summary.destTotals { destTotals[id, default: 0] += count }
            for (id, count) in summary.destCorrect { destCorrect[id, default: 0] += count }
            buckets.append(
                StatsTimeBucket(
                    date: slotDate,
                    generated: summary.generated,
                    misplaced: summary.generated - summary.correct
                )
            )
        }

        return StatsSnapshot(
            generatedTotal: generatedTotal,
            correctlyPlacedCount: correctTotal,
            categoryCounts: binIDs.map { StatsCategoryCount(binID: $0, count: classCounts[$0] ?? 0) },
            placements: binIDs.map { id in
                StatsBinPlacement(
                    binID: id,
                    total: destTotals[id] ?? 0,
                    correct: destCorrect[id] ?? 0
                )
            },
            timeBuckets: buckets
        )
    }

    private static func monthSummary(
        monthStart: Date,
        monthIndex: Int,
        calendar: Calendar
    ) -> MonthSummary {
        guard let interval = calendar.dateInterval(of: .month, for: monthStart) else {
            return MonthSummary(generated: 0, correct: 0, classCounts: [:], destTotals: [:], destCorrect: [:])
        }
        var summary = MonthSummary(generated: 0, correct: 0, classCounts: [:], destTotals: [:], destCorrect: [:])
        var cursor = calendar.startOfDay(for: interval.start)
        let endDay = calendar.startOfDay(for: interval.end)
        var offset = 0
        while cursor < endDay {
            let count = throwCount(on: cursor, calendar: calendar, salt: 3_000 + monthIndex * 97 + offset)
            addMix(count: count, into: &summary)
            offset += 1
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return summary
    }

    private static func addMix(count: Int, into summary: inout MonthSummary) {
        guard count > 0 else { return }
        let sizes = allocate(count, weights: mixBuckets.map(\.weight))
        summary.generated += count
        for (bucket, size) in zip(mixBuckets, sizes) where size > 0 {
            summary.classCounts[bucket.classKey, default: 0] += size
            summary.destTotals[bucket.destination, default: 0] += size
            if BinGuide.isAcceptedDeposit(classKey: bucket.classKey, zoneBinID: bucket.destination) {
                summary.destCorrect[bucket.destination, default: 0] += size
                summary.correct += size
            }
        }
    }
}
