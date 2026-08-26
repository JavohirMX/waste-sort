import Foundation
import os

/// Builds date-ranged teaching-dataset bundles: records.jsonl + referenced
/// crops + manifest.json. Exported record ids land in the manifest, which is
/// also what protects them from pruning forever (invariant I5).
nonisolated enum PCCDatasetExporter {
    private static let log = AppLog.persistence

    nonisolated enum ExportError: Error, Equatable {
        case nothingToExport
        case encodingFailed
    }

    nonisolated struct ExportBundle: Equatable {
        let directoryURL: URL
        let recordCount: Int
        let manifest: PCCRecordStore.ExportManifest
    }

    /// - Returns: bundle location and count, or `.nothingToExport` when the
    ///   range selects zero records — callers surface that honestly (FR-8).
    static func export(
        records range: DateInterval,
        from store: PCCRecordStore,
        now: Date = Date()
    ) throws -> ExportBundle {
        let records = store.records(in: range)
        guard !records.isEmpty else { throw ExportError.nothingToExport }

        let encoder = PCCRecordCodec.makeEncoder()
        let stamp = ISO8601DateFormatter.basicFormat
            .string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        let bundleURL = store.exportsRoot.appendingPathComponent(stamp, isDirectory: true)
        let bundleCrops = bundleURL.appendingPathComponent("crops", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: bundleCrops, withIntermediateDirectories: true)
            var lines = Data()
            var copiedCrops: Set<String> = []
            for record in records {
                lines += try PCCRecordCodec.encodeLine(record, encoder: encoder) + Data("\n".utf8)
                if let cropFile = record.cropFile, copiedCrops.insert(cropFile).inserted {
                    let source = store.rootURL.appendingPathComponent(cropFile)
                    if FileManager.default.fileExists(atPath: source.path) {
                        let destination = bundleCrops.appendingPathComponent(
                            (cropFile as NSString).lastPathComponent
                        )
                        try? FileManager.default.copyItem(at: source, to: destination)
                    }
                }
            }
            try lines.write(to: bundleURL.appendingPathComponent("records.jsonl"), options: .atomic)

            // The failure ledger: every judgment that did not become an answer,
            // as one readable row. This is how "the judge never fired" is told
            // apart from "it fired and failed" after the fact.
            let skips = records.filter { !$0.outcome.isAnswered }
            if !skips.isEmpty {
                try Data(skipsCSV(skips).utf8).write(
                    to: bundleURL.appendingPathComponent("skips.csv"),
                    options: .atomic
                )
            }

            let ids = records.map(\.id)
            let manifest = store.makeExportManifest(exportedAt: now, range: range, recordIds: ids)
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(
                to: bundleURL.appendingPathComponent("manifest.json"),
                options: .atomic
            )
            try Self.fineTuneReadme.write(
                to: bundleURL.appendingPathComponent("README.txt"),
                atomically: true,
                encoding: .utf8
            )
            log.info("PCC judge exported \(ids.count) records (\(skips.count) skipped) to \(bundleURL.lastPathComponent)")
            return ExportBundle(directoryURL: bundleURL, recordCount: ids.count, manifest: manifest)
        } catch {
            log.error("PCC judge export failed: \(error.localizedDescription)")
            throw ExportError.encodingFailed
        }
    }

    /// One CSV row per unanswered judgment, oldest first.
    private static func skipsCSV(_ skips: [PCCVerdictRecord]) throws -> String {
        var rows = ["timestamp,track_id,outcome,detail,yolo_label,engine_bin,uncertain,pipeline"]
        let formatter = ISO8601DateFormatter.basicFormat
        for record in skips.sorted(by: { $0.timestamp < $1.timestamp }) {
            let fields = [
                formatter.string(from: record.timestamp),
                String(record.trackId),
                String(describing: record.outcome),
                record.errorMessage ?? "",
                record.yoloLabel,
                record.engineBinID,
                record.beliefUncertain ? "yes" : "no",
                record.pipeline
            ]
            rows.append(fields.map(Self.csvEscaped).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func csvEscaped(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static let fineTuneReadme = """
        PCC judge export — teaching dataset for YOLO fine-tuning
        ========================================================

        records.jsonl  one judgment per line (JSON). The fields that matter:
                       pccBinID   the bin PCC assigned (the label)
                       cropFile   which image in crops/ it refers to
                       sessionId  groups crops of the same physical item
                       agreesWithEngine  did PCC disagree with the kiosk
        crops/         the exact images the model judged (production 448 px)
        skips.csv      judgments that did NOT become answers (quota, offline,
                       unavailable, timeouts) — how "never fired" is told
                       apart from "fired and failed" after the fact
        manifest.json  export metadata; exported records are never pruned

        Build a train/val classification dataset (session-aware split so
        near-duplicate crops of one item cannot leak across splits):

            python3 scripts/prepare_cls_dataset.py <this folder> -o dataset

        Only answered, successfully-mapped records with a crop are used;
        everything else is dropped and counted. Train your classifier on
        <out>/train and evaluate on <out>/val.
        """
}

private extension ISO8601DateFormatter {
    /// Second-precision timestamp safe for filenames.
    static let basicFormat: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
