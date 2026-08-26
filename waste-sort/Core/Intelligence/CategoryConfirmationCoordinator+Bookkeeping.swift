import CoreGraphics
import Foundation

// MARK: - Bookkeeping (retirement, adoption, verdict application)

extension CategoryConfirmationCoordinator {

    /// Parks the verdicts of tracks that are no longer in the frame, so a dropout does not
    /// silently unlock a category.
    func retireVanishedTracks(stillPresent: Set<Int>, at now: CFAbsoluteTime) {
        let gone = entries.filter { !stillPresent.contains($0.key) }
        guard !gone.isEmpty else { return }
        for (id, entry) in gone {
            if let verdict = entry.verdict {
                orphans.append(Orphan(verdict: verdict, center: entry.center, lostAt: now))
            }
            entries[id] = nil
        }
    }

    /// Starts an entry for a new track, inheriting a nearby parked verdict when there is one.
    ///
    /// Identity here is decided on position alone — deliberately class-blind, since the model
    /// relabelling an item mid-carry is one of the things this layer exists to absorb. The
    /// window each parked verdict is searched in widens with how long it has been missing.
    func adopt(trackID: Int, center: CGPoint, at now: CFAbsoluteTime) -> Entry {
        let entry = Entry(center: center)
        var bestIndex: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, orphan) in orphans.enumerated() {
            let elapsed = max(0, now - orphan.lostAt)
            let limit = min(
                readoptMaxRadius,
                readoptRadius + readoptDriftPerSecond * CGFloat(elapsed)
            )
            let dx = orphan.center.x - center.x
            let dy = orphan.center.y - center.y
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance <= limit, distance < bestDistance else { continue }
            bestDistance = distance
            bestIndex = index
        }
        if let bestIndex {
            entry.verdict = orphans[bestIndex].verdict
            // A re-adopted item is already known, so it is not asked about again.
            entry.frames = minimumTrackFrames
            orphans.remove(at: bestIndex)
        }
        entries[trackID] = entry
        return entry
    }

    func apply(_ verdict: ConfirmedCategory, to track: TrackedDetection) -> TrackedDetection {
        let bin = BinGuide.bin(id: verdict.binID)
        return TrackedDetection(
            id: track.id,
            classKey: bin.id,
            className: bin.title,
            // The model's own confidence, so the label and the number beside it come from
            // the same source. YOLO's score belonged to the class it was outvoted on.
            conf: Float(verdict.confidence),
            displayXywhn: track.displayXywhn,
            misses: track.misses,
            // The detector's own opinion is left exactly as it was. It is what the session
            // log records under `rawClassKey`, and throwing it away would make the two
            // approaches impossible to compare afterwards. `confirmedBinID` is what makes
            // the lock stick: everything that counts reads `TrackedDetection.vote`, which
            // prefers it.
            rawClassKey: track.rawClassKey,
            rawConf: track.rawConf,
            confirmedBinID: bin.id
        )
    }
}
