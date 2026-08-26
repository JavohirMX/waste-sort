import CoreGraphics
import Foundation

/// Associates per-frame detections across time with EMA box smoothing and a per-object
/// `BeliefEngine` vote for the overlay label. Unmatched tracks briefly freeze in place
/// (no velocity coast on display) then drop.
///
/// Label authority is the engine, not any single frame: confidences accumulate with
/// recency decay, and the label only moves when a challenger stays decisively ahead.
/// Tracks also carry the engine's verdict quality (`beliefUncertain`/`beliefMargin`)
/// so the UI can be honest about coin-flip classifications instead of guessing.
final class DetectionTracker {
    var iouThreshold: CGFloat = 0.3
    var confirmHits: Int = 2
    var maxMisses: Int = 3
    var emaAlpha: CGFloat = 0.4
    var boxInflate: CGFloat = 0.08
    /// Max center speed in normalized image widths/heights per second (association only).
    var maxSpeed: CGFloat = 0.8
    /// Velocity multiplier applied on each unmatched frame.
    var missVelocityDecay: CGFloat = 0.25
    /// Overlap required to keep the same track when YOLO changes class.
    /// Capped at `iouThreshold` so a relabel cannot fall into a dead zone.
    var crossClassIouThreshold = CGFloat(WasteSortConfig.defaultCrossClassIou)
    /// Which decision math owns labels and uncertainty reporting. Under `.legacy` every
    /// track also runs a `LegacyDecisionEngine` and belief-specific channels go quiet.
    var pipeline: DecisionPipeline = .belief
    /// Belief knobs mirrored onto every track's engine each frame, so settings changes
    /// reach engines created at different times.
    var beliefHalfLife: CFTimeInterval = WasteSortConfig.defaultBeliefDisplayHalfLife
    var beliefDecideThreshold: Double = WasteSortConfig.defaultBeliefThreshold
    var beliefDecideMargin: Double = WasteSortConfig.defaultBeliefMargin
    /// Total injected weight per appearance sample. Small on purpose: the prior nudges,
    /// the model decides.
    var appearanceEvidenceWeight: Double = WasteSortConfig.defaultAppearanceWeight
    /// Hide a younger confirmed track when it sits on top of an older one.
    var emitOverlapIou: CGFloat = 0.45

    struct Track {
        let id: Int
        var classKey: String
        var className: String
        var lockedConf: Float
        var xywhn: CGRect
        var displayXywhn: CGRect
        var predXywhn: CGRect
        var vx: CGFloat
        var vy: CGFloat
        var hits: Int
        var misses: Int
        var confirmed: Bool
        var matched: Bool
        var t: CFAbsoluteTime
        let belief: BeliefEngine
        /// Window-vote math for the legacy pipeline. Idle under `.belief`.
        var legacy = LegacyDecisionEngine()
        /// Last engine verdict, refreshed only on matched frames. Coasting frames
        /// replay it instead of advancing the engine a second time.
        var lastBelief: BeliefState?
        /// This frame's unfiltered model answer, kept separate from the belief so
        /// consumers can see both what the engine settled on and what YOLO just said.
        var lastRaw: RawDetection?
    }

    var tracks: [Track] = []
    private var nextID = 1

    private var crossClassIou: CGFloat {
        min(crossClassIouThreshold, iouThreshold)
    }

    func reset() {
        tracks.removeAll(keepingCapacity: true)
        nextID = 1
    }

    /// Updates tracks from the latest detections and returns confirmed (matched or frozen coast) tracks.
    func update(_ detections: [RawDetection], timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> [TrackedDetection] {
        let filtered = detections
            .filter { BinGuide.info(for: $0.className).id != "unknown" }
            .sorted { $0.conf > $1.conf }

        for i in tracks.indices {
            tracks[i].belief.config.halfLife = beliefHalfLife
            tracks[i].belief.config.decideThreshold = beliefDecideThreshold
            tracks[i].belief.config.decideMargin = beliefDecideMargin
        }

        for i in tracks.indices {
            let dt = max(timestamp - tracks[i].t, 1e-3)
            // Predict from last matched box for association only — not for display coast.
            let c = center(of: tracks[i].xywhn)
            let s = size(of: tracks[i].xywhn)
            tracks[i].predXywhn = clampNormalized(
                rect(center: CGPoint(x: c.x + tracks[i].vx * dt, y: c.y + tracks[i].vy * dt), size: s)
            )
            tracks[i].matched = false
        }

        var assigned = Set<Int>()
        for (detIndex, det) in filtered.enumerated() {
            guard let bestI = bestMatchIndex(for: det, sameClassOnly: true, iouMin: iouThreshold) else {
                continue
            }
            applyMatch(trackIndex: bestI, det: det, timestamp: timestamp)
            assigned.insert(detIndex)
        }
        for (detIndex, det) in filtered.enumerated() {
            guard !assigned.contains(detIndex) else { continue }
            guard let bestI = bestMatchIndex(for: det, sameClassOnly: false, iouMin: crossClassIou) else {
                continue
            }
            applyMatch(trackIndex: bestI, det: det, timestamp: timestamp)
            assigned.insert(detIndex)
        }

        let leftover = filtered.indices.filter { !assigned.contains($0) }
        for detIndex in leftover {
            let det = filtered[detIndex]
            if overlapsExistingTrack(det) { continue }
            let belief = BeliefEngine(config: .display)
            belief.observe(classKey: det.classKey, className: det.className, conf: det.conf, at: timestamp)
            let track = Track(
                id: nextID,
                classKey: det.classKey,
                className: det.className,
                lockedConf: det.conf,
                xywhn: det.xywhn,
                displayXywhn: det.xywhn,
                predXywhn: det.xywhn,
                vx: 0,
                vy: 0,
                hits: 1,
                misses: 0,
                confirmed: confirmHits <= 1,
                matched: true,
                t: timestamp,
                belief: belief,
                lastBelief: nil,
                lastRaw: det
            )
            nextID += 1
            tracks.append(track)
        }

        var kept: [Track] = []
        for var track in tracks {
            if track.matched {
                kept.append(track)
                continue
            }
            track.misses += 1
            if track.confirmed, track.misses <= maxMisses {
                // Freeze last matched display — do not slide with velocity.
                track.vx *= missVelocityDecay
                track.vy *= missVelocityDecay
                if abs(track.vx) < 1e-4 { track.vx = 0 }
                if abs(track.vy) < 1e-4 { track.vy = 0 }
                track.t = timestamp
                kept.append(track)
            }
        }
        tracks = kept
        return suppressOverlapping(tracks.filter(\.confirmed)).map { emit($0) }
    }

    /// Fuses a completed zoom re-check into a track's belief. Real model output, so it
    /// counts toward the minimum-evidence gate; `weight` is pre-boosted by the caller.
    /// Called from `update`'s queue after draining the recheck buffer.
    func injectRecheck(
        trackID: Int,
        classKey: String,
        className: String,
        conf: Float,
        weight: Float,
        at timestamp: CFAbsoluteTime
    ) {
        guard pipeline == .belief,
              let i = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[i].belief.inject(
            classKey: classKey,
            className: className,
            weight: Double(weight),
            at: timestamp,
            countsAsEvidence: true
        )
        tracks[i].lastBelief = tracks[i].belief.currentState(at: timestamp)
        if let state = tracks[i].lastBelief,
           let locked = state.lockedClassKey, locked != tracks[i].classKey {
            tracks[i].classKey = locked
            tracks[i].className = state.classNameByKey[locked] ?? className
            tracks[i].lockedConf = Float(state.probabilities[locked] ?? 0)
        }
    }

}
