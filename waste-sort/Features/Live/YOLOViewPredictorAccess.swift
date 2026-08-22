import AVFoundation
import UltralyticsYOLO

/// The single sanctioned seam into UltralyticsYOLO's private internals.
///
/// The package (pinned at 8.9.13, upToNextMajor) does not expose its
/// `VideoCapture`, predictor, or camera queue. Everything that needs them goes
/// through this file so an upgrade that renames those members fails in exactly
/// one place: these lookups return nil, degrading AprilTag detection and raw
/// frame capture instead of crashing.
enum YOLOViewPredictorAccess {
    static func setCapturesOriginalImage(_ enabled: Bool, in view: YOLOView) {
        predictor(in: view)?.capturesOriginalImage = enabled
    }

    static func predictor(in view: YOLOView) -> BasePredictor? {
        videoCapture(in: view)?.predictor as? BasePredictor
    }

    static func videoCapture(in view: YOLOView) -> VideoCapture? {
        mirroredValue(in: view, label: "videoCapture")
    }

    static func cameraQueue(in capture: VideoCapture) -> DispatchQueue? {
        if let queued = videoOutput(in: capture)?.sampleBufferCallbackQueue {
            return queued
        }
        return mirroredValue(in: capture, label: "cameraQueue")
    }

    static func videoOutput(in capture: VideoCapture) -> AVCaptureVideoDataOutput? {
        mirroredValue(in: capture, label: "videoOutput")
    }

    private static func mirroredValue<T>(in object: Any, label: String) -> T? {
        let mirror = Mirror(reflecting: object)
        for child in mirror.children where child.label == label {
            return child.value as? T
        }
        return nil
    }
}
