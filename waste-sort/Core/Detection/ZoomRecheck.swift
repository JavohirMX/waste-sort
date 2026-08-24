import CoreGraphics
import Foundation
import UIKit
import UltralyticsYOLO

/// A completed second-look inference for one track, ready to be fused as evidence.
nonisolated struct ZoomRecheckOutcome: Equatable, Sendable {
    let trackID: Int
    let classKey: String
    let className: String
    let conf: Float
}

/// Escalation pass for unsure items: crop the region at native resolution and run the
/// same segmentation model on just that crop.
///
/// The full frame is letterboxed to 640×640 before YOLO sees it, so a hand-sized item
/// a metre from the lens lands well under 100 input pixels — exactly where class
/// confidences get mushy. Re-running on a tight crop roughly multiplies effective
/// resolution, which resolves most borderline reads. Results are injected into the
/// track's belief engine as boosted evidence (real model output, so it counts toward
/// the minimum-evidence gate).
///
/// Threading: owned by the Coordinator alongside the tracker. `request` must be called
/// on the inference queue; inference itself runs on this engine's own serial queue and
/// never blocks frame handling — at most one re-check is in flight, newer requests for
/// a busy pipeline are dropped (same policy as barcode scanning).
final class ZoomRecheckEngine {
    /// Per-track trigger bookkeeping: how long the item has been unsure, whether it is
    /// holding still, and when it was last re-checked.
    private struct TrackState {
        var uncertainSince: CFAbsoluteTime?
        var lastCenter: CGPoint?
        var lastRequestAt: CFAbsoluteTime = 0
    }

    private var states: [Int: TrackState] = [:]
    private var model: YOLO?
    private var loadedModelName: String?
    private let queue = DispatchQueue(label: "sortla.zoom-recheck", qos: .utility)
    private var inFlight = false

    func reset() {
        states.removeAll()
    }

    /// Drops the cached model so the next request reloads fresh weights.
    func invalidateModel() {
        queue.async { [weak self] in
            self?.model = nil
            self?.loadedModelName = nil
        }
    }

    /// Updates an item's uncertainty clock and returns true when a re-check should fire.
    ///
    /// Called once per frame per confirmed track, on the inference queue.
    func shouldRecheck(
        track: TrackedDetection,
        timestamp: CFAbsoluteTime,
        delay: CFAbsoluteTime,
        cooldown: CFAbsoluteTime,
        maxDriftPerFrame: CGFloat
    ) -> Bool {
        guard !track.isCoasting else {
            states[track.id]?.uncertainSince = nil
            return false
        }
        var state = states[track.id] ?? TrackState()
        defer { states[track.id] = state }

        if !track.beliefUncertain {
            state.uncertainSince = nil
            return false
        }
        if state.uncertainSince == nil {
            state.uncertainSince = timestamp
        }
        guard let since = state.uncertainSince,
              timestamp - since >= delay,
              timestamp - state.lastRequestAt >= cooldown
        else { return false }

        // Only hold-still items are worth a second look; a moving blur crops badly
        // and the answer would be stale by delivery anyway.
        let center = CGPoint(x: track.displayXywhn.midX, y: track.displayXywhn.midY)
        if let last = state.lastCenter {
            let dx = center.x - last.x
            let dy = center.y - last.y
            guard (dx * dx + dy * dy).squareRoot() <= maxDriftPerFrame else {
                state.lastCenter = center
                state.uncertainSince = timestamp
                return false
            }
        }
        state.lastCenter = center
        state.lastRequestAt = timestamp
        return true
    }

    /// Crops `boxNorm` (padded) from the frame and runs the model on the zoomed crop.
    func request(
        image: UIImage,
        boxNorm: CGRect,
        trackID: Int,
        modelName: String,
        settings: RuntimeSettings,
        completion: @escaping (ZoomRecheckOutcome?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, !self.inFlight else {
                completion(nil)
                return
            }
            guard let cropped = Self.crop(image: image, around: boxNorm) else {
                completion(nil)
                return
            }
            self.inFlight = true
            self.ensureModel(named: modelName, settings: settings)

            guard let model = self.model else {
                self.inFlight = false
                completion(nil)
                return
            }

            let result = model(cropped)
            let minConf = Float(settings.confidence)
            let best = result.boxes.max { $0.conf < $1.conf }
            self.inFlight = false

            guard let best, best.conf >= minConf else {
                completion(nil)
                return
            }
            completion(
                ZoomRecheckOutcome(
                    trackID: trackID,
                    classKey: BinGuide.normalizedKey(best.cls),
                    className: best.cls,
                    conf: best.conf
                )
            )
        }
    }

    /// Padded square-ish crop in pixel space, clamped to the image.
    static func crop(image: UIImage, around boxNorm: CGRect) -> UIImage? {
        guard let cgImage = image.cgImageOrRendered else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let clamped = boxNorm.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, clamped.width > 0.005, clamped.height > 0.005 else { return nil }
        // Pad by a third of the box so context around the item survives the model's
        // letterboxing; too little background and edges read wrong.
        let padW = clamped.width * 0.35
        let padH = clamped.height * 0.35
        let padded = CGRect(
            x: clamped.minX - padW,
            y: clamped.minY - padH,
            width: clamped.width + padW * 2,
            height: clamped.height + padH * 2
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixelRect = CGRect(
            x: (padded.minX * width).rounded(.down),
            y: (padded.minY * height).rounded(.down),
            width: max((padded.width * width).rounded(), 16),
            height: max((padded.height * height).rounded(), 16)
        )
        guard let cropped = cgImage.cropping(to: pixelRect.integral) else { return nil }
        return UIImage(cgImage: cropped)
    }

    /// Idempotent model load/threshold refresh; runs on the engine's own queue.
    private func ensureModel(named name: String, settings: RuntimeSettings) {
        if let model, loadedModelName == name {
            model.setConfidenceThreshold(settings.confidence)
            model.setIouThreshold(settings.iou)
            model.setNumItemsThreshold(settings.maxItems)
            return
        }
        let loaded = YOLO(name, task: .segment) { _ in }
        loaded.setConfidenceThreshold(settings.confidence)
        loaded.setIouThreshold(settings.iou)
        loaded.setNumItemsThreshold(settings.maxItems)
        model = loaded
        loadedModelName = name
    }
}
