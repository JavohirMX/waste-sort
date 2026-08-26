import AVFoundation
import Foundation

/// Pure math for matching the recorded stream's orientation to the live preview.
///
/// Extracted from `RecordingController` so the angle mapping can be reasoned
/// about (and tested) without an active capture session. The AVFoundation
/// mutation glue stays with the controller.
nonisolated enum VideoRotationMath {
    /// Wraps an angle into `0..<360`.
    static func clampedAngle(_ angle: CGFloat) -> CGFloat {
        var target = angle.truncatingRemainder(dividingBy: 360)
        if target < 0 { target += 360 }
        return target
    }

    /// Nearest 90° step, matching `LivePreviewRotation`.
    static func quantized(_ angle: CGFloat) -> LivePreviewRotation {
        let step = (Int((clampedAngle(angle) / 90).rounded()) * 90) % 360
        switch step {
        case 90: return .ninety
        case 180: return .oneEighty
        case 270: return .twoSeventy
        default: return .zero
        }
    }

    /// Adds two preview rotations, wrapping at 360°.
    static func composed(
        _ lhs: LivePreviewRotation,
        _ rhs: LivePreviewRotation
    ) -> LivePreviewRotation {
        quantized(CGFloat(lhs.rawValue + rhs.rawValue))
    }

    /// Extra overlay rotation needed when the preview layer and the inference
    /// buffers do not share an orientation. Zero when they already match.
    static func presentationDelta(
        previewAngle: CGFloat,
        bufferAngle: CGFloat
    ) -> LivePreviewRotation {
        quantized(previewAngle - bufferAngle)
    }

    /// `videoRotationAngle` equivalent of a legacy `AVCaptureVideoOrientation`.
    static func angle(from orientation: AVCaptureVideoOrientation) -> CGFloat {
        switch orientation {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeRight: return 180
        case .landscapeLeft: return 0
        @unknown default: return 0
        }
    }

    /// Inverse of `angle(from:)` for connections that only accept the legacy API.
    static func orientation(fromAngle angle: CGFloat) -> AVCaptureVideoOrientation {
        switch quantized(angle) {
        case .zero: return .landscapeLeft
        case .ninety: return .portrait
        case .oneEighty: return .landscapeRight
        case .twoSeventy: return .portraitUpsideDown
        }
    }

    /// Target rotation angle for a movie connection, given the video feed's base angle.
    static func targetRotationAngle(baseAngle: CGFloat, rotation: LivePreviewRotation) -> CGFloat {
        clampedAngle(baseAngle + CGFloat(rotation.rawValue))
    }

    /// Front cameras capture mirrored; honour the user's mirror preference on top.
    static func shouldMirror(isFrontCamera: Bool?, mirrorPreference: Bool) -> Bool {
        (isFrontCamera == true) != mirrorPreference
    }

    /// Fallback for connections that predate `videoRotationAngle`: pick a legacy
    /// orientation matching the requested rotation as closely as the API allows.
    static func legacyOrientation(
        base: AVCaptureVideoOrientation,
        rotation: LivePreviewRotation
    ) -> AVCaptureVideoOrientation {
        let flipped180: AVCaptureVideoOrientation
        switch base {
        case .portrait: flipped180 = .portraitUpsideDown
        case .portraitUpsideDown: flipped180 = .portrait
        case .landscapeRight: flipped180 = .landscapeLeft
        case .landscapeLeft: flipped180 = .landscapeRight
        @unknown default: flipped180 = base
        }

        switch rotation {
        case .zero:
            return base
        case .oneEighty, .ninety, .twoSeventy:
            // The legacy API has no 90° steps here; 180° is the closest match.
            return flipped180
        }
    }
}
