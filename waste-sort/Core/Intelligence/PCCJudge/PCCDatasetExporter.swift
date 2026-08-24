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
            let ids = records.map(\.id)
            let manifest = store.makeExportManifest(exportedAt: now, range: range, recordIds: ids)
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(
                to: bundleURL.appendingPathComponent("manifest.json"),
                options: .atomic
            )
            log.info("PCC judge exported \(ids.count) records to \(bundleURL.lastPathComponent)")
            return ExportBundle(directoryURL: bundleURL, recordCount: ids.count, manifest: manifest)
        } catch {
            log.error("PCC judge export failed: \(error.localizedDescription)")
            throw ExportError.encodingFailed
        }
    }
}

private extension ISO8601DateFormatter {
    /// Second-precision timestamp safe for filenames.
    static let basicFormat: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
