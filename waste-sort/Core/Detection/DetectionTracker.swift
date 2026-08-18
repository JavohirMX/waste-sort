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
    let conf: Float
    /// Inflated display rect in normalized coordinates.
    let displayXywhn: CGRect
    /// Consecutive frames the model has failed to find this track. Zero means the box
    /// comes from a real detection this frame; anything higher means it is frozen in
    /// place, still drawn but no longer evidence that the object is there.
    var misses: Int = 0

    var isCoasting: Bool { misses > 0 }
}

/// Associates per-frame detections across time with EMA box smoothing and sticky class labels.
/// Unmatched tracks briefly freeze in place (no velocity coast on display) then drop.
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
    var crossClassIouThreshold: CGFloat = CGFloat(WasteSortConfig.defaultCrossClassIou)
    /// Consecutive disagreeing frames before the emitted bin label switches.
    var classSwitchHits: Int = WasteSortConfig.defaultClassSwitchHits
    /// Hide a younger confirmed track when it sits on top of an older one.
    var emitOverlapIou: CGFloat = 0.45

    private struct Track {
        let id: Int
        var classKey: String
        var className: String
        var conf: Float
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
        var pendingClassKey: String?
        var pendingClassName: String
        var pendingHits: Int
    }

    private var tracks: [Track] = []
    private var nextID = 1

    func reset() {
        tracks.removeAll(keepingCapacity: true)
        nextID = 1
    }

    /// Updates tracks from the latest detections and returns confirmed (matched or frozen coast) tracks.
    func update(_ detections: [RawDetection], timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> [TrackedDetection] {
        let filtered = detections.filter { BinGuide.info(for: $0.className).id != "unknown" }

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
            guard let bestI = bestMatchIndex(for: det, sameClassOnly: false, iouMin: crossClassIouThreshold) else {
                continue
            }
            applyMatch(trackIndex: bestI, det: det, timestamp: timestamp)
            assigned.insert(detIndex)
        }

        let leftover = filtered.indices.filter { !assigned.contains($0) }
            .sorted { filtered[$0].conf > filtered[$1].conf }
        for detIndex in leftover {
            let det = filtered[detIndex]
            if overlapsExistingTrack(det) { continue }
            let track = Track(
                id: nextID,
                classKey: det.classKey,
                className: det.className,
                conf: det.conf,
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
                pendingClassKey: nil,
                pendingClassName: "",
                pendingHits: 0
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
        let visibleIDs = Set(suppressOverlapping(kept.filter(\.confirmed)).map(\.id))
        tracks = kept.filter { !$0.confirmed || visibleIDs.contains($0.id) }
        return tracks.filter(\.confirmed).map { emit($0) }
    }

    private func emit(_ track: Track) -> TrackedDetection {
        TrackedDetection(
            id: track.id,
            classKey: track.classKey,
            className: track.className,
            conf: track.conf,
            displayXywhn: inflate(track.displayXywhn),
            misses: track.misses
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
        tracks[i].hits += 1
        tracks[i].misses = 0
        tracks[i].vx = vx
        tracks[i].vy = vy
        tracks[i].xywhn = det.xywhn
        tracks[i].displayXywhn = ema(tracks[i].displayXywhn, det.xywhn)
        tracks[i].conf = det.conf
        tracks[i].t = timestamp
        if tracks[i].hits >= confirmHits {
            tracks[i].confirmed = true
        }

        if det.classKey == tracks[i].classKey {
            tracks[i].pendingClassKey = nil
            tracks[i].pendingHits = 0
        } else if tracks[i].pendingClassKey == det.classKey {
            tracks[i].pendingHits += 1
            tracks[i].pendingClassName = det.className
            if tracks[i].pendingHits >= classSwitchHits {
                tracks[i].classKey = det.classKey
                tracks[i].className = det.className
                tracks[i].pendingClassKey = nil
                tracks[i].pendingHits = 0
            }
        } else {
            tracks[i].pendingClassKey = det.classKey
            tracks[i].pendingClassName = det.className
            tracks[i].pendingHits = 1
            if classSwitchHits <= 1 {
                tracks[i].classKey = det.classKey
                tracks[i].className = det.className
                tracks[i].pendingClassKey = nil
                tracks[i].pendingHits = 0
            }
        }
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
