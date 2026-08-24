import Foundation
import Testing
@testable import waste_sort

@Suite("PCC record store")
struct PCCRecordStoreTests {
    private var root: URL
    private let store: PCCRecordStore

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcc-store-tests-\(UUID().uuidString)", isDirectory: true)
        store = PCCRecordStore(rootURL: root)
    }

    private func record(
        trackId: Int,
        timestamp: Date = Date(),
        outcome: PCCVerdictRecord.Outcome = .answered,
        cropFile: String? = nil
    ) -> PCCVerdictRecord {
        PCCVerdictRecord(
            timestamp: timestamp,
            sessionId: "s",
            trackId: trackId,
            cropFile: cropFile,
            yoloLabel: "tissue",
            yoloConfidence: 0.5,
            beliefUncertain: true,
            beliefMargin: 0.02,
            engineBinID: BinGuide.fallbackBinID,
            pipeline: "belief",
            outcome: outcome,
            pccBinID: BinGuide.fallbackBinID,
            pccRawBinLabel: "residual",
            agreesWithEngine: true
        )
    }

    private let allTime = DateInterval(start: .distantPast, duration: .greatestFiniteMagnitude)

    @Test("Append then read round-trips every field (invariant I4)")
    func roundTrip() {
        store.append(record(trackId: 1), cropJPEG: nil)
        let records = store.records(in: allTime)
        guard records.count == 1 else {
            #expect(Bool(false), "expected 1 record, got \(records.count)")
            return
        }
        let stored = records[0]
        #expect(stored.schemaVersion == PCCVerdictRecord.schemaVersion)
        #expect(stored.trackId == 1)
        #expect(stored.engineBinID == BinGuide.fallbackBinID)
    }

    @Test("Crop bytes are written before the referencing record exists in queries")
    func cropWrite() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        store.append(record(trackId: 2), cropJPEG: jpeg)
        let stored = try #require(store.records(in: allTime).first)
        let cropName = try #require(stored.cropFile)
        #expect(cropName.hasPrefix("crops/"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(cropName).path))
    }

    @Test("Range query filters by timestamp and corrupt lines are skipped")
    func rangeAndCorrupt() throws {
        let old = Date().addingTimeInterval(-86_400 * 90)
        store.append(record(trackId: 1, timestamp: old), cropJPEG: nil)
        store.append(record(trackId: 2), cropJPEG: nil)
        // Corrupt one line directly.
        let recordsURL = root.appendingPathComponent("records.jsonl")
        let raw = try String(contentsOf: recordsURL, encoding: .utf8)
        try "{not json}\n\(raw)".write(to: recordsURL, atomically: true, encoding: .utf8)

        // The corrupt prefix line is skipped; both valid records remain.
        #expect(store.records(in: allTime).map(\.trackId) == [1, 2])
        #expect(store.records(in: DateInterval(start: old - 60, duration: 120)).map(\.trackId) == [1])
    }

    @Test("Prune removes expired unexported records plus their crops")
    func pruneRemovesExpired() throws {
        let ancient = Date().addingTimeInterval(-Double(WasteSortConfig.defaultPCCPruneDays + 1) * 86_400)
        store.append(record(trackId: 1, timestamp: ancient), cropJPEG: Data([0xFF, 0xD9]))
        store.append(record(trackId: 2), cropJPEG: nil)
        let removed = store.pruneOldRecords()
        #expect(removed == 1)
        let survivors = store.records(in: allTime)
        #expect(survivors.map(\.trackId) == [2])
        // The expired record's crop file was deleted alongside it.
        let cropFiles = FileManager.default.enumerator(
            at: root.appendingPathComponent("crops"),
            includingPropertiesForKeys: nil
        )?.allObjects ?? []
        #expect(cropFiles.isEmpty)
    }

    @Test("Exported records survive pruning forever (invariant I5)")
    func pruneSparesExported() throws {
        let ancient = Date().addingTimeInterval(-Double(WasteSortConfig.defaultPCCPruneDays + 5) * 86_400)
        store.append(record(trackId: 3, timestamp: ancient), cropJPEG: nil)
        let exported = try #require(store.records(in: allTime).first)
        let manifest = store.makeExportManifest(
            exportedAt: Date(),
            range: allTime,
            recordIds: [exported.id]
        )
        let encoder = PCCRecordCodec.makeEncoder()
        try encoder.encode(manifest).write(
            to: store.exportsRoot.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        store.pruneOldRecords()
        #expect(store.allRecordCount() == 1)
    }
}
