import AVFoundation
import Foundation

// MARK: - Capture-session plumbing (outputs, notifications, rotation)

extension RecordingController {
    func observeCaptureSession(_ session: AVCaptureSession?) {
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        sessionObservers.removeAll()
        guard let session else { return }

        let center = NotificationCenter.default
        sessionObservers = [
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                self?.flushAndSave()
            },
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                self?.flushAndSave()
            }
        ]
    }

    @discardableResult
    func ensureMovieOutput(on session: AVCaptureSession) -> Bool {
        if session.outputs.contains(where: { $0 === movieOutput }) {
            return movieOutput.connection(with: .video) != nil
        }
        guard session.canAddOutput(movieOutput) else {
            return false
        }
        session.beginConfiguration()
        session.addOutput(movieOutput)
        session.commitConfiguration()
        return movieOutput.connection(with: .video) != nil
    }

    func makeRecordingURL() -> URL {
        recordingsDirectory.appendingPathComponent("waste-sort-\(UUID().uuidString).mov")
    }

    /// Rotates and optionally mirrors the recorded stream to match the Live preview snapshot.
    func applyFeedRotation(to connection: AVCaptureConnection, session: AVCaptureSession) {
        let baseAngle = session.outputs
            .compactMap { $0 as? AVCaptureVideoDataOutput }
            .first?
            .connection(with: .video)?
            .videoRotationAngle ?? 0

        let target = VideoRotationMath.targetRotationAngle(baseAngle: baseAngle, rotation: sessionRotation)
        if connection.isVideoRotationAngleSupported(target) {
            connection.videoRotationAngle = target
        } else {
            let baseOrientation = session.outputs
                .compactMap { $0 as? AVCaptureVideoDataOutput }
                .first?
                .connection(with: .video)?
                .videoOrientation ?? .portrait
            connection.videoOrientation = VideoRotationMath.legacyOrientation(
                base: baseOrientation,
                rotation: sessionRotation
            )
        }

        guard connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        let isFront = session.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first { $0.device.hasMediaType(.video) }?
            .device.position == .front
        connection.isVideoMirrored = VideoRotationMath.shouldMirror(
            isFrontCamera: isFront,
            mirrorPreference: sessionMirror
        )
    }
}
