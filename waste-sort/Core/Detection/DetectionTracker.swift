import CoreGraphics
import Foundation

/// Lightweight detection used as tracker input (normalized image coordinates).
struct RawDetection: Equatable, Sendable {
    let classKey: String
    let className: String
    let conf: Float
    /// Normalized rect (0…1) in image space, origin top-left.
    let xywhn: CGRect
    /// Soft color/texture evidence sampled inside the box, when appearance assist is on.
    var appearancePrior: AppearancePrior?
}

/// Confirmed track ready for overlay drawing and counting.
struct TrackedDetection: Identifiable, Equatable, Sendable {
    let id: Int
    let classKey: String
    let className: String
    /// Last confidence observed for the locked class (not the current YOLO challenger).
    let conf: Float
    /// Inflated display rect in normalized coordinates.
    let displayXywhn: CGRect
    /// Consecutive frames the model has failed to find this track. Zero means the box
    /// comes from a real detection this frame; anything higher means it is frozen in
    /// place, still drawn but no longer evidence that the object is there.
    var misses: Int = 0
    /// This frame's belief leader. Empty means the same as `classKey`.
    var rawClassKey: String = ""
    /// Belief probability of this frame's leader (0 when nothing was seen yet).
    var rawConf: Float = 0
    /// True while the belief engine would not back `classKey` with a verdict —
    /// the UI should present this as "not sure", not as a confident answer.
    var beliefUncertain: Bool = false
    /// Lead of the belief leader over the runner-up, 0…1. Small values flag coin flips.
    var beliefMargin: Float = 0

    var isCoasting: Bool { misses > 0 }

    var observedClassKey: String { rawClassKey.isEmpty ? classKey : rawClassKey }

    var isClassPending: Bool { !rawClassKey.isEmpty && rawClassKey != classKey }
}

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

    private struct Track {
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

    private var tracks: [Track] = []
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

    private func emit(_ track: Track) -> TrackedDetection {
        // Legacy has no uncertainty concept: it always answers as if sure, which is
        // exactly the behavior the toggle exists to reproduce.
        guard pipeline == .belief else {
            return TrackedDetection(
                id: track.id,
                classKey: track.classKey,
                className: track.className,
                conf: track.lockedConf,
                displayXywhn: inflate(track.displayXywhn),
                misses: track.misses,
                rawClassKey: "",
                rawConf: 0,
                beliefUncertain: false,
                beliefMargin: 0
            )
        }
        let state = track.lastBelief
        let raw = track.lastRaw
        return TrackedDetection(
            id: track.id,
            classKey: track.classKey,
            className: track.className,
            conf: track.lockedConf,
            displayXywhn: inflate(track.displayXywhn),
            misses: track.misses,
            rawClassKey: raw?.classKey ?? "",
            rawConf: raw?.conf ?? 0,
            beliefUncertain: track.confirmed ? (state?.isUncertain ?? true) : false,
            beliefMargin: state.map { Float($0.margin) } ?? 0
        )
    }

    private func overlapsExistingTrack(_ det: RawDetection) -> Bool {
        tracks.contains { iou($0.xywhn, det.xywhn) >= iouThreshold }
    }

    private func suppressOverlapping(_ confirmed: [Track]) -> [Track] {
        let oldestFirst = confirmed.sorted { $0.id < $1.id }
        var kept: [Track] = []
        for track in oldestFirst {
            let overlapsOlder = kept.contains { iou($0.displayXywhn, track.displayXywhn) >= emitOverlapIou }
            if overlapsOlder { continue }
            kept.append(track)
        }
        return kept
    }

    private func bestMatchIndex(for det: RawDetection, sameClassOnly: Bool, iouMin: CGFloat) -> Int? {
        var bestI = -1
        var bestIoU: CGFloat = 0
        for (i, track) in tracks.enumerated() {
            if track.matched { continue }
            if sameClassOnly, track.classKey != det.classKey { continue }
            let value = iou(track.predXywhn, det.xywhn)
            if value > bestIoU {
                bestIoU = value
                bestI = i
            }
        }
        guard bestI >= 0, bestIoU >= iouMin else { return nil }
        return bestI
    }

    private func applyMatch(trackIndex i: Int, det: RawDetection, timestamp: CFAbsoluteTime) {
        let dt = max(timestamp - tracks[i].t, 1e-3)
        let oldC = center(of: tracks[i].xywhn)
        let newC = center(of: det.xywhn)
        let (vx, vy) = clampVelocity(
            (newC.x - oldC.x) / dt,
            (newC.y - oldC.y) / dt
        )

        tracks[i].matched = true
        tracks[i].misses = 0
        tracks[i].vx = vx
        tracks[i].vy = vy
        tracks[i].xywhn = det.xywhn
        tracks[i].displayXywhn = ema(tracks[i].displayXywhn, det.xywhn)
        tracks[i].t = timestamp
        tracks[i].lastRaw = det

        if !tracks[i].confirmed {
            if det.classKey == tracks[i].classKey {
                tracks[i].hits += 1
            } else {
                // Confirmation needs agreeing frames; a disagreeing frame restarts the
                // count under the challenger. The engine sees everything regardless.
                tracks[i].classKey = det.classKey
                tracks[i].className = det.className
                tracks[i].hits = 1
            }
            tracks[i].lockedConf = det.conf
            if tracks[i].hits >= confirmHits {
                tracks[i].confirmed = true
            }
        } else if det.classKey == tracks[i].classKey {
            tracks[i].lockedConf = det.conf
        }

        if pipeline == .legacy {
            // Main's math: window vote owns the label once the window fills. No belief,
            // no appearance channel, no uncertainty.
            tracks[i].legacy.observe(
                classKey: det.classKey,
                className: det.className,
                conf: det.conf,
                at: timestamp
            )
            let voted = tracks[i].legacy.label
            if voted != tracks[i].classKey {
                tracks[i].classKey = voted
                tracks[i].className = BinGuide.bin(id: voted).title
            }
            return
        }

        tracks[i].belief.observe(
            classKey: det.classKey,
            className: det.className,
            conf: det.conf,
            at: timestamp
        )
        // Soft color/texture evidence rides along when sampled this frame; it shifts
        // shares without counting toward the minimum-evidence gate.
        if let prior = det.appearancePrior {
            for (key, share) in prior.shares {
                tracks[i].belief.inject(
                    classKey: key,
                    className: BinGuide.bin(id: key).title,
                    weight: share * appearanceEvidenceWeight,
                    at: timestamp,
                    countsAsEvidence: false
                )
            }
        }
        let state = tracks[i].belief.currentState(at: timestamp)
        tracks[i].lastBelief = state
        // The engine's stable lock outranks the raw class once it exists; this is what
        // absorbs a single-frame flicker without waiting for the window to agree.
        if let locked = state.lockedClassKey, locked != tracks[i].classKey, trackConfirmedLongEnough(i) {
            tracks[i].classKey = locked
            tracks[i].className = state.classNameByKey[locked] ?? det.className
            tracks[i].lockedConf = Float(state.probabilities[locked] ?? 0)
        }
    }

    /// Guards label flips until confirmation finished, so `confirmHits` disagreement
    /// handling stays authoritative for newborn tracks.
    private func trackConfirmedLongEnough(_ i: Int) -> Bool {
        tracks[i].confirmed
    }

    private func ema(_ prev: CGRect, _ new: CGRect) -> CGRect {
        let a = emaAlpha
        return CGRect(
            x: a * new.origin.x + (1 - a) * prev.origin.x,
            y: a * new.origin.y + (1 - a) * prev.origin.y,
            width: a * new.size.width + (1 - a) * prev.size.width,
            height: a * new.size.height + (1 - a) * prev.size.height
        )
    }

    private func inflate(_ rect: CGRect) -> CGRect {
        let c = center(of: rect)
        let s = size(of: rect)
        return self.rect(
            center: c,
            size: CGSize(width: s.width * (1 + boxInflate), height: s.height * (1 + boxInflate))
        )
    }

    private func clampVelocity(_ vx: CGFloat, _ vy: CGFloat) -> (CGFloat, CGFloat) {
        let speed = (vx * vx + vy * vy).squareRoot()
        guard speed > maxSpeed, speed > 1e-6 else { return (vx, vy) }
        let scale = maxSpeed / speed
        return (vx * scale, vy * scale)
    }

    /// Keeps association search windows inside normalized image bounds.
    private func clampNormalized(_ rect: CGRect) -> CGRect {
        let width = min(max(rect.width, 0), 1)
        let height = min(max(rect.height, 0), 1)
        let x = min(max(rect.origin.x, 0), 1 - width)
        let y = min(max(rect.origin.y, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private func size(of rect: CGRect) -> CGSize {
        CGSize(width: max(0, rect.width), height: max(0, rect.height))
    }

    private func rect(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(
            x: center.x - size.width * 0.5,
            y: center.y - size.height * 0.5,
            width: size.width,
            height: size.height
        )
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        guard union > 0 else { return 0 }
        return interArea / union
    }
}
