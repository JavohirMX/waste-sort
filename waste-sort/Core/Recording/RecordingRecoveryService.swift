import Foundation
import os

/// Scans the Recordings directory for clips left behind by a crash or force-quit,
/// decides which are usable, and clears the persisted "active file" keys once
/// nothing is left to recover.
///
/// Extracted from `RecordingController` so file-system policy lives apart from
/// the recording phase machine. MainActor because it reads/writes UserDefaults.
@MainActor
final class RecordingRecoveryService {
    private let directory: URL
    private let activeFileKey: String
    private let activeAnnotatedFileKey: String
    private let defaults: UserDefaults

    init(
        directory: URL,
        activeFileKey: String,
        activeAnnotatedFileKey: String,
        defaults: UserDefaults = .standard
    ) {
        self.directory = directory
        self.activeFileKey = activeFileKey
        self.activeAnnotatedFileKey = activeAnnotatedFileKey
        self.defaults = defaults
    }

    struct RecoveredAnnotated {
        let url: URL
        /// Session prefix without the "-annotated" suffix, e.g. `Sortla-2026-08-14-150932`.
        let prefix: String
    }

    /// Usable raw (non-annotated) leftovers. Clears the persisted raw-file key when none remain.
    func recoverRawRecordings() -> [URL] {
        let files = usableLeftovers { url in
            !url.lastPathComponent.lowercased().contains("annotated")
        }
        if files.isEmpty {
            defaults.removeObject(forKey: activeFileKey)
        }
        return files
    }

    /// Usable annotated leftovers. Clears the persisted annotated-file key when none remain.
    func recoverAnnotatedRecordings() -> [RecoveredAnnotated] {
        let files = usableLeftovers { url in
            url.lastPathComponent.lowercased().contains("annotated")
        }
        if files.isEmpty {
            defaults.removeObject(forKey: activeAnnotatedFileKey)
            return []
        }
        return files.map { url in
            let prefix = url.deletingPathExtension()
                .lastPathComponent
                .replacingOccurrences(of: "-annotated", with: "")
            return RecoveredAnnotated(url: url, prefix: prefix)
        }
    }

    /// A recording counts as usable only if it exists and holds at least 1 KB;
    /// smaller files are AVFoundation fragments with no playable content.
    func usableRecordingURL(_ url: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        guard
            let attrs = try? fm.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? NSNumber,
            size.intValue >= 1024
        else {
            AppLog.recording.error("Skipping unusable recording \(url.lastPathComponent): missing, unreadable, or <1 KB")
            return nil
        }
        return url
    }

    // MARK: - Private

    private func usableLeftovers(matching: (URL) -> Bool) -> [URL] {
        let fm = FileManager.default
        let listed = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var urls = listed.filter {
            $0.pathExtension.lowercased() == "mov" && matching($0)
        }

        // Persisted paths survive even when the directory listing misses them
        // (e.g. container moves); fold them in so nothing recoverable is skipped.
        for key in [activeFileKey, activeAnnotatedFileKey] {
            if let path = defaults.string(forKey: key) {
                let persisted = URL(fileURLWithPath: path)
                if matching(persisted),
                   fm.fileExists(atPath: persisted.path),
                   !urls.contains(where: { $0.path == persisted.path }) {
                    urls.append(persisted)
                }
            }
        }

        var usable: [URL] = []
        for url in urls {
            if usableRecordingURL(url) != nil {
                usable.append(url)
            } else {
                do {
                    try fm.removeItem(at: url)
                } catch {
                    AppLog.recording.error("Could not discard unusable recording \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return usable
    }
}
