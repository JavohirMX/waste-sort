import Foundation

/// Canned deposit events for previewing Stats. Never written to History JSONL.
nonisolated enum StatsMockData {
    /// Design mock “bins filled” counts (not destination throw totals).
    static let binsFilled: [String: Int] = [
        BinGuide.organic.id: 6,
        BinGuide.residual.id: 8,
        BinGuide.cleanInorganic.id: 3
    ]

    /// Design mock category bar heights (sum 142) for Daily overlay — taller organic fill on 0…100 domain.
    static let categoryCounts: [String: Int] = [
        BinGuide.organic.id: 80,
        BinGuide.residual.id: 42,
        BinGuide.cleanInorganic.id: 20
    ]

    /// Stable UUIDs so snapshots stay comparable in tests.
    private static let organicZone = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private static let residualZone = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private static let recyclableZone = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    static func events(now: Date = Date(), calendar: Calendar = .current) -> [ZoneEventRecord] {
        var records: [ZoneEventRecord] = []
        records.append(contentsOf: todayEvents(now: now, calendar: calendar))
        records.append(contentsOf: weekExtras(now: now, calendar: calendar))
        records.append(contentsOf: monthExtras(now: now, calendar: calendar))
        records.append(contentsOf: yearExtras(now: now, calendar: calendar))
        return records.sorted { $0.timestamp > $1.timestamp }
    }

    /// Daily timeline shaped like the design crop (Y domain 0…200).
    /// Angular vertices (hour + minute) for piecewise linear interpolation.
    static func dailyTimelineBuckets(now: Date = Date(), calendar: Calendar = .current) -> [StatsTimeBucket] {
        let startOfDay = calendar.startOfDay(for: now)
        // Design: ~68 at 7am → slight rise → dip ~50 → climb → plateau ~190 ~5:30pm → ~140 at 7pm.
        let points: [DesignPoint] = [
            DesignPoint(hour: 7, minute: 0, generated: 68, misplaced: 18),
            DesignPoint(hour: 8, minute: 30, generated: 72, misplaced: 20),
            DesignPoint(hour: 10, minute: 30, generated: 50, misplaced: 10),
            DesignPoint(hour: 13, minute: 0, generated: 85, misplaced: 25),
            DesignPoint(hour: 15, minute: 0, generated: 160, misplaced: 60),
            DesignPoint(hour: 16, minute: 0, generated: 180, misplaced: 78),
            DesignPoint(hour: 17, minute: 30, generated: 190, misplaced: 82),
            DesignPoint(hour: 19, minute: 0, generated: 140, misplaced: 55)
        ]
        return points.compactMap { point in
            guard let hourDate = calendar.date(byAdding: .hour, value: point.hour, to: startOfDay),
                  let date = calendar.date(byAdding: .minute, value: point.minute, to: hourDate)
            else {
                return nil
            }
            return StatsTimeBucket(
                date: date,
                generated: point.generated,
                misplaced: point.misplaced
            )
        }
    }

    /// Design vertex for the daily timeline: time-of-day plus generated/misplaced counts.
    private struct DesignPoint {
        let hour: Int
        let minute: Int
        let generated: Int
        let misplaced: Int
    }

    /// ~142 throws today; category mix skewed like the bar design (organic tallest).
    private static func todayEvents(now: Date, calendar: Calendar) -> [ZoneEventRecord] {
        let startOfDay = calendar.startOfDay(for: now)
        // Total 142; roughly organic 55%, residual 30%, recyclable 15% → ~78 / 43 / 21
        let classCycle = [
            BinGuide.organic.id, BinGuide.organic.id, BinGuide.organic.id,
            BinGuide.organic.id, BinGuide.organic.id,
            BinGuide.residual.id, BinGuide.residual.id, BinGuide.residual.id,
            BinGuide.cleanInorganic.id
        ]
        // Spread across day for history; timeline chart uses dailyTimelineBuckets when mock is on.
        let hourWeights: [Int: Int] = [
            7: 8, 8: 9, 9: 10, 10: 8, 11: 9, 12: 12,
            13: 13, 14: 14, 15: 15, 16: 16, 17: 14, 18: 9, 19: 5
        ]
        var records: [ZoneEventRecord] = []
        var seed = 0
        for (hour, count) in hourWeights.sorted(by: { $0.key < $1.key }) {
            guard let hourStart = calendar.date(byAdding: .hour, value: hour, to: startOfDay) else {
                continue
            }
            for i in 0..<count {
                let minutes = (i * 57) % 60
                let seconds = (i * 13) % 60
                guard let stamp = calendar.date(
                    byAdding: .second,
                    value: minutes * 60 + seconds,
                    to: hourStart
                ) else { continue }
                let classKey = classCycle[seed % classCycle.count]
                records.append(makeEvent(at: stamp, seed: seed, classKey: classKey))
                seed += 1
            }
        }
        return records
    }

    private static func weekExtras(now: Date, calendar: Calendar) -> [ZoneEventRecord] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }
        var records: [ZoneEventRecord] = []
        var cursor = week.start
        var seed = 1_000
        while cursor < week.end {
            if !calendar.isDate(cursor, inSameDayAs: now) {
                for i in 0..<8 {
                    guard let stamp = calendar.date(byAdding: .hour, value: 10 + i, to: cursor) else {
                        continue
                    }
                    records.append(makeEvent(at: stamp, seed: seed))
                    seed += 1
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return records
    }

    private static func monthExtras(now: Date, calendar: Calendar) -> [ZoneEventRecord] {
        guard let month = calendar.dateInterval(of: .month, for: now),
              let week = calendar.dateInterval(of: .weekOfYear, for: now)
        else { return [] }
        var records: [ZoneEventRecord] = []
        var cursor = month.start
        var seed = 2_000
        while cursor < month.end {
            if cursor < week.start || cursor >= week.end {
                for i in 0..<5 {
                    guard let stamp = calendar.date(byAdding: .hour, value: 11 + i, to: cursor) else {
                        continue
                    }
                    records.append(makeEvent(at: stamp, seed: seed))
                    seed += 1
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return records
    }

    private static func yearExtras(now: Date, calendar: Calendar) -> [ZoneEventRecord] {
        guard let year = calendar.dateInterval(of: .year, for: now),
              let month = calendar.dateInterval(of: .month, for: now)
        else { return [] }
        var records: [ZoneEventRecord] = []
        var cursor = year.start
        var seed = 3_000
        while cursor < year.end {
            if cursor < month.start || cursor >= month.end {
                for dayOffset in [3, 12, 20] {
                    guard let day = calendar.date(byAdding: .day, value: dayOffset, to: cursor),
                          let stamp = calendar.date(byAdding: .hour, value: 14, to: day)
                    else { continue }
                    records.append(makeEvent(at: stamp, seed: seed))
                    seed += 1
                }
            }
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return records
    }

    private static func makeEvent(
        at date: Date,
        seed: Int,
        classKey: String? = nil
    ) -> ZoneEventRecord {
        let classes = [BinGuide.organic.id, BinGuide.residual.id, BinGuide.cleanInorganic.id]
        let resolvedClass = classKey ?? classes[seed % 3]
        let destination: String
        let isCorrect: Bool
        if seed % 3 == 0 {
            destination = classes[(seed + 1) % 3]
            isCorrect = false
        } else {
            destination = resolvedClass
            isCorrect = true
        }
        let zoneID: UUID
        switch destination {
        case BinGuide.organic.id: zoneID = organicZone
        case BinGuide.residual.id: zoneID = residualZone
        default: zoneID = recyclableZone
        }
        return ZoneEventRecord(
            id: UUID(),
            timestamp: date,
            classKey: resolvedClass,
            className: resolvedClass,
            zoneID: zoneID,
            zoneName: BinGuide.bin(id: destination).displayName.capitalized,
            zoneBinID: destination,
            confidence: 0.7 + Double(seed % 20) / 100,
            isCorrect: isCorrect,
            viaTrajectory: false,
            binWasOpen: true
        )
    }
}
