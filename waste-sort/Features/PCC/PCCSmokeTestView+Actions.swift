import Photos
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Async probe actions

extension PCCSmokeTestView {
    func importPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else {
                errorMessage = "Could not read that photo."
                return
            }
            await judgePhoto(image)
        } catch {
            errorMessage = "Could not read that photo."
        }
    }

    func judgePhoto(_ image: UIImage) async {
        guard let judge else {
            errorMessage = "Judge is not ready yet — try again in a moment."
            return
        }
        errorMessage = nil
        judgment = nil
        sourceImage = image
        isJudging = true
        defer { isJudging = false }

        guard let frameCG = UprightFrameImage.cgImage(from: image) else {
            errorMessage = "Could not read that image."
            return
        }
        let crop = smokeCrop(from: frameCG)
        nextTrackID += 1
        let context = ArbiterRequestContext(
            trackId: nextTrackID,
            sessionId: "photo-smoke",
            yoloLabel: "photo_smoke",
            yoloConfidence: 0,
            beliefUncertain: false,
            beliefMargin: 0,
            engineBinID: BinGuide.unknown.id,
            pipeline: "photo-smoke",
            triggeredAt: Date()
        )
        judgment = await judge.smokeJudge(context, crop: crop)
        availability = PCCJudgeAvailability.current
    }

    /// Whole-frame "crop", downscaled to the SAME size the live judge sends
    /// (448 px). Measured on the iOS 27 sim: 512 px answered in ~1.3 s while
    /// 1024 px took 6–8 s and straddled the 10 s timeout — the smoke screen
    /// must exercise the shape production uses, not a heavier one.
    func smokeCrop(from frameCG: CGImage) -> CGImage {
        ItemCropper.crop(
            frameCG,
            to: CGRect(x: 0, y: 0, width: 1, height: 1),
            padding: WasteSortConfig.defaultPCCCropPadding,
            maximumSide: WasteSortConfig.defaultPCCCropMaximumSide,
            minimumSide: WasteSortConfig.defaultPCCCropMinimumPixels
        ) ?? frameCG
    }

    /// Decisive bisection: the SAME prompt and normalized image sent to the
    /// on-device model. On-device answer + PCC rejection = the image content
    /// is fine and the PCC image pipeline is what rejects it (beta
    /// limitation, worth a Feedback). Both fail = the content itself trips
    /// guardrails; try a different photo.
    func runAFMCrossCheck() async {
        guard let afmJudge, let sourceImage else { return }
        afmJudgment = nil
        isCrossChecking = true
        defer { isCrossChecking = false }
        guard let frameCG = UprightFrameImage.cgImage(from: sourceImage) else {
            errorMessage = "Could not read that image."
            return
        }
        nextTrackID += 1
        let context = ArbiterRequestContext(
            trackId: nextTrackID,
            sessionId: "photo-smoke",
            yoloLabel: "photo_smoke",
            yoloConfidence: 0,
            beliefUncertain: false,
            beliefMargin: 0,
            engineBinID: BinGuide.unknown.id,
            pipeline: "photo-smoke-afm",
            triggeredAt: Date()
        )
        afmJudgment = await afmJudge.smokeJudge(context, crop: smokeCrop(from: frameCG))
        availability = PCCJudgeAvailability.current
    }

    func runTextProbe() async {
        guard let judge else { return }
        probeJudgment = nil
        isProbing = true
        defer { isProbing = false }

        // Tiny placeholder bitmap: the pipeline requires a crop to record, but
        // the text-probe transport never attaches it.
        let probeCrop = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ).flatMap { $0.makeImage() }

        nextTrackID += 1
        let context = ArbiterRequestContext(
            trackId: nextTrackID,
            sessionId: "photo-smoke",
            yoloLabel: PCCTextProbe.label,
            yoloConfidence: 0,
            beliefUncertain: false,
            beliefMargin: 0,
            engineBinID: BinGuide.unknown.id,
            pipeline: "photo-smoke",
            triggeredAt: Date()
        )
        probeJudgment = await judge.smokeJudge(context, crop: probeCrop)
        availability = PCCJudgeAvailability.current
    }
}

