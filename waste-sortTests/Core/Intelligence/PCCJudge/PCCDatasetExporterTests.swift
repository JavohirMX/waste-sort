import Foundation
import Testing
@testable import waste_sort

@Suite("PCC dataset exporter")
struct PCCDatasetExporterTests {
    private var root: URL
    private let store: PCCRecordStore

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcc-export-tests-\(UUID().uuidString)", isDirectory: true)
        store = PCCRecordStore(rootURL: root)
    }

    private func seed(trackId: Int, timestamp: Date) throws -> PCCVerdictRecord {
        let record = PCCVerdictRecord(
            sessionId: "s",
            trackId: trackId,
            cropFile: nil,
            yoloLabel: "tissue",
            yoloConfidence: 0.5,
            beliefUncertain: true,
            beliefMargin: 0.02,
            engineBinID: BinGuide.fallbackBinID,
            pipeline: "belief",
            outcome: .answered,
            pccRawBinLabel: "residual"
        )
        var stored = record
        stored.timestamp = timestamp
        store.append(stored, cropJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        return stored
    }

    /// A judgment that never became an answer — quota, offline, timeout…
    private func seedSkip(trackId: Int, timestamp: Date) throws {
        let record = PCCVerdictRecord(
            sessionId: "s",
            trackId: trackId,
            cropFile: nil,
            yoloLabel: "chip bag",
            yoloConfidence: 0.4,
            beliefUncertain: false,
            beliefMargin: 0.5,
            engineBinID: BinGuide.residual.id,
            pipeline: "belief",
            outcome: .skippedQuota
        )
        var stored = record
        stored.timestamp = timestamp
        store.append(stored, cropJPEG: nil)
    }

    private let allTime = DateInterval(start: .distantPast, duration: .greatestFiniteMagnitude)

    @Test("Empty range exports nothing and says so honestly")
    func emptyRange() {
        #expect(throws: PCCDatasetExporter.ExportError.nothingToExport) {
            try PCCDatasetExporter.export(records: allTime, from: store)
        }
    }

    @Test("Bundle carries a fine-tuning README pointing at the dataset script")
    func bundleReadme() throws {
        try seed(trackId: 1, timestamp: Date())
        let bundle = try PCCDatasetExporter.export(records: allTime, from: store)
        let readme = try String(
            contentsOf: bundle.directoryURL.appendingPathComponent("README.txt"),
            encoding: .utf8
        )
        #expect(readme.contains("prepare_cls_dataset.py"))
        #expect(readme.contains("pccBinID"))
    }

    @Test("Minute-precision ranges select sub-day slices (spec 003 export)")
    func minutePrecisionRange() throws {
        let now = Date()
        try seed(trackId: 1, timestamp: now.addingTimeInterval(-600))
        try seed(trackId: 2, timestamp: now.addingTimeInterval(-3_600 * 5))
        // 30-minute window catches only the recent record — no day snapping.
        let range = DateInterval(start: now.addingTimeInterval(-1_800), end: now)
        let bundle = try PCCDatasetExporter.export(records: range, from: store)
        #expect(bundle.recordCount == 1)
    }

    @Test("Bundle contains valid JSONL for every record, referenced crops, and a manifest")
    func bundleRoundTrip() throws {
        let now = Date()
        try seed(trackId: 1, timestamp: now.addingTimeInterval(-60))
        try seed(trackId: 2, timestamp: now.addingTimeInterval(-30))
        // Out of range — must be excluded.
        try seed(trackId: 3, timestamp: now.addingTimeInterval(-86_400 * 10))

        let range = DateInterval(start: now.addingTimeInterval(-120), end: now)
        let bundle = try PCCDatasetExporter.export(records: range, from: store)

        #expect(bundle.recordCount == 2)
        let jsonlURL = bundle.directoryURL.appendingPathComponent("records.jsonl")
        let raw = try String(contentsOf: jsonlURL, encoding: .utf8)
        let decoder = PCCRecordCodec.makeDecoder()
        var ids = Set<UUID>()
        for line in raw.split(separator: "\n") {
            let record = try #require(try? decoder.decode(PCCVerdictRecord.self, from: Data(line.utf8)))
            ids.insert(record.id)
            if let cropFile = record.cropFile {
                #expect(
                    FileManager.default.fileExists(
                        atPath: bundle.directoryURL.appendingPathComponent(cropFile).path
                    )
                )
            }
        }
        #expect(ids.count == 2)
        #expect(bundle.manifest.recordIds.count == 2)
        #expect(bundle.manifest.schemaVersion == PCCVerdictRecord.schemaVersion)
    }

    @Test("Exported records are prune-protected through their manifest (I5 end-to-end)")
    func exportProtectsFromPrune() throws {
        let ancient = Date().addingTimeInterval(-Double(WasteSortConfig.defaultPCCPruneDays + 1) * 86_400)
        try seed(trackId: 9, timestamp: ancient)
        _ = try PCCDatasetExporter.export(records: allTime, from: store)
        store.pruneOldRecords()
        #expect(store.allRecordCount() == 1)
    }

    @Test("Unanswered judgments land in skips.csv with their reasons")
    func skipsAreExportedAsReadableRows() throws {
        let now = Date()
        try seed(trackId: 1, timestamp: now.addingTimeInterval(-60))
        try seedSkip(trackId: 2, timestamp: now.addingTimeInterval(-40))
        try seedSkip(trackId: 3, timestamp: now.addingTimeInterval(-20))

        let bundle = try PCCDatasetExporter.export(records: allTime, from: store)
        #expect(bundle.recordCount == 3)

        let csv = try String(
            contentsOf: bundle.directoryURL.appendingPathComponent("skips.csv"),
            encoding: .utf8
        )
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.count == 3, "header + one row per skipped judgment")
        #expect(lines[0].hasPrefix("timestamp,track_id,outcome"))
        #expect(lines[1].contains("2"))
        #expect(lines[1].contains("skippedQuota"))
        // Oldest first.
        #expect(lines[1].contains(",2,") && lines[2].contains(",3,"))
    }

    @Test("A bundle with only answered judgments ships no skips.csv")
    func allAnsweredShipsNoSkipsFile() throws {
        try seed(trackId: 1, timestamp: Date())
        let bundle = try PCCDatasetExporter.export(records: allTime, from: store)
        #expect(
            !FileManager.default.fileExists(
                atPath: bundle.directoryURL.appendingPathComponent("skips.csv").path
            )
        )
    }
}
