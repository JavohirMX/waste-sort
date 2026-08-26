import AVFoundation
import os
import UIKit
import UltralyticsYOLO

/// Switches YOLOView's live capture input by reconfiguring the session behind its preview layer.
///
/// Part of the Ultralytics adapter surface (see `YOLOViewPredictorAccess`):
/// Ultralytics exposes no public device picker, so this keeps inference on the
/// same session while swapping the input.
enum YOLOViewCameraSwitcher {
    @discardableResult
    static func switchTo(_ device: AVCaptureDevice, in view: YOLOView) -> Bool {
        guard let previewLayer = findPreviewLayer(in: view.layer),
              let session = previewLayer.session
        else {
            return false
        }

        let currentVideoInput = session.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first { $0.device.hasMediaType(.video) }

        if currentVideoInput?.device.uniqueID == device.uniqueID {
            AVCaptureDevice.userPreferredCamera = device
            return true
        }

        let newInput: AVCaptureDeviceInput
        do {
            newInput = try AVCaptureDeviceInput(device: device)
        } catch {
            AppLog.pipeline.error("Camera input creation failed for \(device.uniqueID): \(error.localizedDescription)")
            return false
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let currentVideoInput {
            session.removeInput(currentVideoInput)
        }

        guard session.canAddInput(newInput) else {
            if let currentVideoInput, session.canAddInput(currentVideoInput) {
                session.addInput(currentVideoInput)
            }
            return false
        }

        session.addInput(newInput)

        let mirror = device.position == .front
        for output in session.outputs {
            for connection in output.connections where connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirror
            }
        }
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirror
        }

        AVCaptureDevice.userPreferredCamera = device
        return true
    }

    /// Copies the preview layer's actual rotation onto the video data output so
    /// YOLO / AprilTag / overlay coordinates match the pixels on screen.
    ///
    /// Returns the leftover overlay delta when the assignment does not stick
    /// (common on UVC bridges that accept `videoRotationAngle` on one connection
    /// and ignore it on the other).
    @discardableResult
    static func syncInferenceOrientation(in view: YOLOView) -> LivePreviewRotation {
        let previewLayer = YOLOViewPredictorAccess.videoCapture(in: view)?.previewLayer
            ?? findPreviewLayer(in: view.layer)
        guard let previewLayer else { return .zero }

        let previewAngle = rotationAngle(of: previewLayer.connection)
        guard let connection = videoDataConnection(in: view) else {
            AppLog.pipeline.error("Inference orientation sync skipped: video data output missing")
            return .zero
        }

        let before = rotationAngle(of: connection)
        if VideoRotationMath.presentationDelta(previewAngle: previewAngle, bufferAngle: before) == .zero {
            return .zero
        }

        let session = previewLayer.session ?? captureSession(in: view)
        session?.beginConfiguration()
        let applied = apply(previewAngle, to: connection)
        session?.commitConfiguration()

        let after = rotationAngle(of: connection)
        let delta = VideoRotationMath.presentationDelta(
            previewAngle: previewAngle,
            bufferAngle: after
        )
        if delta == .zero {
            AppLog.pipeline.info("Synced inference orientation to preview \(Int(previewAngle))°")
        } else {
            AppLog.pipeline.error(
                "Inference orientation mismatch: preview \(Int(previewAngle))° buffer \(Int(after))° applied=\(applied)"
            )
        }
        return delta
    }

    static func currentVideoDevice(in view: YOLOView) -> AVCaptureDevice? {
        guard let session = captureSession(in: view) else { return nil }
        return session.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first { $0.device.hasMediaType(.video) }?
            .device
    }

    static func currentDeviceUniqueID(in view: YOLOView) -> String? {
        currentVideoDevice(in: view)?.uniqueID
    }

    static func captureSession(in view: YOLOView) -> AVCaptureSession? {
        findPreviewLayer(in: view.layer)?.session
    }

    private static func videoDataConnection(in view: YOLOView) -> AVCaptureConnection? {
        guard let capture = YOLOViewPredictorAccess.videoCapture(in: view),
              let output = YOLOViewPredictorAccess.videoOutput(in: capture)
        else {
            return nil
        }
        return output.connection(with: .video)
    }

    private static func rotationAngle(of connection: AVCaptureConnection?) -> CGFloat {
        guard let connection else { return 0 }
        return connection.videoRotationAngle
    }

    @discardableResult
    private static func apply(_ angle: CGFloat, to connection: AVCaptureConnection) -> Bool {
        let target = VideoRotationMath.clampedAngle(angle)
        if connection.isVideoRotationAngleSupported(target) {
            connection.videoRotationAngle = target
            return true
        }
        guard connection.isVideoOrientationSupported else { return false }
        connection.videoOrientation = VideoRotationMath.orientation(fromAngle: target)
        return true
    }

    private static func findPreviewLayer(in layer: CALayer) -> AVCaptureVideoPreviewLayer? {
        if let preview = layer as? AVCaptureVideoPreviewLayer {
            return preview
        }
        for sublayer in layer.sublayers ?? [] {
            if let found = findPreviewLayer(in: sublayer) {
                return found
            }
        }
        return nil
    }
}
