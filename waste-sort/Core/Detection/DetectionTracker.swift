import CoreGraphics
import Foundation

/// Lightweight detection used as tracker input (normalized image coordinates).
struct RawDetection: Equatable, Sendable {
    let classKey: String
    let className: String
    let conf: Float
    /// Normalized rect (0…1) in image space, origin top-left.
    let xywhn: CGRect
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
    /// This frame's YOLO class. Empty means the same as `classKey`.
    var rawClassKey: String = ""
    var rawConf: Float = 0

    var isCoasting: Bool { misses > 0 }

    var observedClassKey: String { rawClassKey.isEmpty ? classKey : rawClassKey }

    var isClassPending: Bool { !rawClassKey.isEmpty && rawClassKey != classKey }
}

/// Associates per-frame detections across time with EMA box smoothing and a time-window
/// confidence vote for the overlay label. Unmatched tracks briefly freeze in place
/// (no velocity coast on display) then drop.
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
    /// Wall-clock window the challenger class must lead (by summed confidence) before
    /// the overlay label switches.
    var classLockWindow: CFTimeInterval = WasteSortConfig.defaultClassLockWindow
    /// Hide a younger confirmed track when it sits on top of an older one.
    var emitOverlapIou: CGFloat = 0.45

    private struct ClassSample {
        var t: CFAbsoluteTime
        var classKey: String
        var className: String
        var conf: Float
    }

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
        var samples: [ClassSample]
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
            let sample = ClassSample(
                t: timestamp,
                classKey: det.classKey,
                className: det.className,
                conf: det.conf
            )
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
                samples: [sample]
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

    private func emit(_ track: Track) -> TrackedDetection {
        let last = track.samples.last
        return TrackedDetection(
            id: track.id,
            classKey: track.classKey,
            className: track.className,
            conf: track.lockedConf,
            displayXywhn: inflate(track.displayXywhn),
            misses: track.misses,
            rawClassKey: last?.classKey ?? track.classKey,
            rawConf: last?.conf ?? track.lockedConf
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
        tracks[i].samples.append(
            ClassSample(t: timestamp, classKey: det.classKey, className: det.className, conf: det.conf)
        )
        let cutoff = timestamp - classLockWindow
        tracks[i].samples.removeAll { $0.t < cutoff }

        if !tracks[i].confirmed {
            if det.classKey == tracks[i].classKey {
                tracks[i].hits += 1
            } else {
                tracks[i].classKey = det.classKey
                tracks[i].className = det.className
                tracks[i].hits = 1
            }
            tracks[i].lockedConf = det.conf
            if tracks[i].hits >= confirmHits {
                tracks[i].confirmed = true
            }
            return
        }

        if det.classKey == tracks[i].classKey {
            tracks[i].lockedConf = det.conf
        }
        guard let first = tracks[i].samples.first, let last = tracks[i].samples.last,
              last.t - first.t >= classLockWindow
        else { return }
        applyVote(trackIndex: i)
    }

    private func applyVote(trackIndex i: Int) {
        var weights: [String: Float] = [:]
        var names: [String: String] = [:]
        var lastConf: [String: Float] = [:]
        for sample in tracks[i].samples {
            weights[sample.classKey, default: 0] += sample.conf
            names[sample.classKey] = sample.className
            lastConf[sample.classKey] = sample.conf
        }
        let current = tracks[i].classKey
        let currentWeight = weights[current] ?? 0
        guard let best = weights.max(by: { a, b in
            a.value == b.value ? a.key > b.key : a.value < b.value
        }) else { return }
        guard best.key != current, best.value > currentWeight else { return }
        tracks[i].classKey = best.key
        tracks[i].className = names[best.key] ?? tracks[i].className
        tracks[i].lockedConf = lastConf[best.key] ?? tracks[i].lockedConf
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
