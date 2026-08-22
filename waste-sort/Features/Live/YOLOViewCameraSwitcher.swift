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
