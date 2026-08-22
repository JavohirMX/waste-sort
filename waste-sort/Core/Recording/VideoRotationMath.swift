import AVFoundation
import Foundation

/// Pure math for matching the recorded stream's orientation to the live preview.
///
/// Extracted from `RecordingController` so the angle mapping can be reasoned
/// about (and tested) without an active capture session. The AVFoundation
/// mutation glue stays with the controller.
nonisolated enum VideoRotationMath {
    /// Target rotation angle for a movie connection, given the video feed's base angle.
    static func targetRotationAngle(baseAngle: CGFloat, rotation: LivePreviewRotation) -> CGFloat {
        var target = (baseAngle + CGFloat(rotation.rawValue)).truncatingRemainder(dividingBy: 360)
        if target < 0 { target += 360 }
        return target
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
