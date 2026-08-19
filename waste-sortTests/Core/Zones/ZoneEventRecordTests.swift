import Foundation
import Testing
@testable import waste_sort

@Suite("ZoneEventRecord Tests")
struct ZoneEventRecordTests {
    @Test("CSV row output includes binWasOpen field")
    func csvFormatting() {
        let recordOpen = ZoneEventRecord(
            timestamp: Date(timeIntervalSince1970: 1700000000),
            classKey: "organic",
            className: "Apple Core",
            zoneID: UUID(),
            zoneName: "Organic Bin",
            zoneBinID: "organic",
            confidence: 0.95,
            isCorrect: true,
            binWasOpen: true
        )

        let csvOpen = recordOpen.csvRow()
        #expect(csvOpen.contains(",true,0.9500") || csvOpen.contains(",true,true,0.9500"))

        let recordClosed = ZoneEventRecord(
            timestamp: Date(timeIntervalSince1970: 1700000000),
            classKey: "residual",
            className: "Plastic Bag",
            zoneID: UUID(),
            zoneName: "Residual Bin",
            zoneBinID: "residual",
            confidence: 0.88,
            isCorrect: true,
            binWasOpen: false
        )

        let csvClosed = recordClosed.csvRow()
        #expect(csvClosed.contains("false,0.8800"))
        #expect(ZoneEventRecord.csvHeader.contains("binWasOpen"))
        #expect(ZoneEventRecord.csvHeader.contains("viaTrajectory"))
    }

    @Test("Legacy JSON decoding defaults binWasOpen to true")
    func legacyJSONDecoding() throws {
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "timestamp": "2026-08-19T10:00:00.000Z",
            "classKey": "organic",
            "className": "Banana",
            "zoneID": "\(UUID().uuidString)",
            "zoneName": "Organic",
            "zoneBinID": "organic",
            "confidence": 0.92,
            "isCorrect": true
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601Fractional
        let record = try decoder.decode(ZoneEventRecord.self, from: Data(legacyJSON.utf8))
        #expect(record.binWasOpen == true)
        #expect(record.className == "Banana")
    }

    @Test("JSON roundtrip preserves binWasOpen false")
    func jsonRoundtrip() throws {
        let record = ZoneEventRecord(
            timestamp: Date(),
            classKey: "clean_inorganic",
            className: "Can",
            zoneID: UUID(),
            zoneName: "Recycle",
            zoneBinID: "clean_inorganic",
            confidence: 0.99,
            isCorrect: true,
            binWasOpen: false
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601Fractional
        let data = try encoder.encode(record)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601Fractional
        let decoded = try decoder.decode(ZoneEventRecord.self, from: data)

        #expect(decoded.binWasOpen == false)
        #expect(decoded.className == "Can")
        #expect(decoded.isCorrect == true)
        #expect(decoded.viaTrajectory == nil)
    }

    @Test("JSON roundtrip preserves viaTrajectory")
    func viaTrajectoryRoundtrip() throws {
        let record = ZoneEventRecord(
            timestamp: Date(),
            classKey: "organic",
            className: "Banana",
            zoneID: UUID(),
            zoneName: "Organic",
            zoneBinID: "organic",
            confidence: 0.91,
            isCorrect: true,
            viaTrajectory: true,
            binWasOpen: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601Fractional
        let data = try encoder.encode(record)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601Fractional
        let decoded = try decoder.decode(ZoneEventRecord.self, from: data)

        #expect(decoded.viaTrajectory == true)
        #expect(decoded.binWasOpen == true)
    }
}
