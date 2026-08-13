import CoreGraphics
import Foundation

/// Lightweight detection used as tracker input (normalized image coordinates).
struct RawDetection: Equatable {
    let classKey: String
    let className: String
    let conf: Float
    /// Normalized rect (0…1) in image space, origin top-left.
    let xywhn: CGRect
}

/// Confirmed track ready for overlay drawing and counting.
struct TrackedDetection: Identifiable, Equatable {
    let id: Int
    let classKey: String
    let className: String
    let conf: Float
    /// Inflated display rect in normalized coordinates.
    let displayXywhn: CGRect
}

/// Associates per-frame detections across time with EMA smoothing and constant-velocity coasting.
final class DetectionTracker {
    var iouThreshold: CGFloat = 0.3
    var confirmHits: Int = 2
    var maxMisses: Int = 8
    var emaAlpha: CGFloat = 0.4
    var boxInflate: CGFloat = 0.08
    /// Max center speed in normalized image widths/heights per second.
    var maxSpeed: CGFloat = 2.0

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
    }

    private var tracks: [Track] = []
    private var nextID = 1

    func reset() {
        tracks.removeAll(keepingCapacity: true)
        nextID = 1
    }

    /// Updates tracks from the latest detections and returns confirmed (matched or coasting) tracks.
    func update(_ detections: [RawDetection], timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> [TrackedDetection] {
        let filtered = detections.filter { BinGuide.info(for: $0.className).id != "unknown" }

        for i in tracks.indices {
            let dt = max(timestamp - tracks[i].t, 1e-3)
            let c = center(of: tracks[i].displayXywhn)
            let s = size(of: tracks[i].xywhn)
            tracks[i].predXywhn = rect(center: CGPoint(x: c.x + tracks[i].vx * dt, y: c.y + tracks[i].vy * dt), size: s)
            tracks[i].matched = false
        }

        var assigned = Set<Int>()
        for (detIndex, det) in filtered.enumerated() {
            var bestI = -1
            var bestIoU: CGFloat = 0
            for (i, track) in tracks.enumerated() {
                if track.matched || track.classKey != det.classKey { continue }
                let value = iou(track.predXywhn, det.xywhn)
                if value > bestIoU {
                    bestIoU = value
                    bestI = i
                }
            }
            guard bestI >= 0, bestIoU >= iouThreshold else { continue }

            let dt = max(timestamp - tracks[bestI].t, 1e-3)
            let oldC = center(of: tracks[bestI].xywhn)
            let newC = center(of: det.xywhn)
            let (vx, vy) = clampVelocity(
                (newC.x - oldC.x) / dt,
                (newC.y - oldC.y) / dt
            )

            tracks[bestI].matched = true
            tracks[bestI].hits += 1
            tracks[bestI].misses = 0
            tracks[bestI].vx = vx
            tracks[bestI].vy = vy
            tracks[bestI].xywhn = det.xywhn
            tracks[bestI].displayXywhn = ema(tracks[bestI].predXywhn, det.xywhn)
            tracks[bestI].conf = det.conf
            tracks[bestI].className = det.className
            tracks[bestI].classKey = det.classKey
            tracks[bestI].t = timestamp
            if tracks[bestI].hits >= confirmHits {
                tracks[bestI].confirmed = true
            }
            assigned.insert(detIndex)
        }

        for (detIndex, det) in filtered.enumerated() {
            guard !assigned.contains(detIndex) else { continue }
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
                t: timestamp
            )
            nextID += 1
            tracks.append(track)
        }

        var confirmed: [TrackedDetection] = []
        var kept: [Track] = []
        for var track in tracks {
            if track.matched {
                kept.append(track)
                if track.confirmed {
                    confirmed.append(emit(track))
                }
                continue
            }
            track.misses += 1
            if track.confirmed, track.misses <= maxMisses {
                track.displayXywhn = track.predXywhn
                track.t = timestamp
                kept.append(track)
                confirmed.append(emit(track))
            }
        }
        tracks = kept
        return confirmed
    }

    private func emit(_ track: Track) -> TrackedDetection {
        TrackedDetection(
            id: track.id,
            classKey: track.classKey,
            className: track.className,
            conf: track.conf,
            displayXywhn: inflate(track.displayXywhn)
        )
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
