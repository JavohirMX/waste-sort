import CoreGraphics
import Foundation

// MARK: - Matching, belief application, and geometry helpers

extension DetectionTracker {
    func emit(_ track: Track) -> TrackedDetection {
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

    func overlapsExistingTrack(_ det: RawDetection) -> Bool {
        tracks.contains { iou($0.xywhn, det.xywhn) >= iouThreshold }
    }

    func suppressOverlapping(_ confirmed: [Track]) -> [Track] {
        let oldestFirst = confirmed.sorted { $0.id < $1.id }
        var kept: [Track] = []
        for track in oldestFirst {
            let overlapsOlder = kept.contains { iou($0.displayXywhn, track.displayXywhn) >= emitOverlapIou }
            if overlapsOlder { continue }
            kept.append(track)
        }
        return kept
    }

    func bestMatchIndex(for det: RawDetection, sameClassOnly: Bool, iouMin: CGFloat) -> Int? {
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

    func applyMatch(trackIndex i: Int, det: RawDetection, timestamp: CFAbsoluteTime) {
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
    func trackConfirmedLongEnough(_ i: Int) -> Bool {
        tracks[i].confirmed
    }

    func ema(_ prev: CGRect, _ new: CGRect) -> CGRect {
        let a = emaAlpha
        return CGRect(
            x: a * new.origin.x + (1 - a) * prev.origin.x,
            y: a * new.origin.y + (1 - a) * prev.origin.y,
            width: a * new.size.width + (1 - a) * prev.size.width,
            height: a * new.size.height + (1 - a) * prev.size.height
        )
    }

    func inflate(_ rect: CGRect) -> CGRect {
        let c = center(of: rect)
        let s = size(of: rect)
        return self.rect(
            center: c,
            size: CGSize(width: s.width * (1 + boxInflate), height: s.height * (1 + boxInflate))
        )
    }

    func clampVelocity(_ vx: CGFloat, _ vy: CGFloat) -> (CGFloat, CGFloat) {
        let speed = (vx * vx + vy * vy).squareRoot()
        guard speed > maxSpeed, speed > 1e-6 else { return (vx, vy) }
        let scale = maxSpeed / speed
        return (vx * scale, vy * scale)
    }

    /// Keeps association search windows inside normalized image bounds.
    func clampNormalized(_ rect: CGRect) -> CGRect {
        let width = min(max(rect.width, 0), 1)
        let height = min(max(rect.height, 0), 1)
        let x = min(max(rect.origin.x, 0), 1 - width)
        let y = min(max(rect.origin.y, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    func size(of rect: CGRect) -> CGSize {
        CGSize(width: max(0, rect.width), height: max(0, rect.height))
    }

    func rect(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(
            x: center.x - size.width * 0.5,
            y: center.y - size.height * 0.5,
            width: size.width,
            height: size.height
        )
    }

    func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        guard union > 0 else { return 0 }
        return interArea / union
    }
}
