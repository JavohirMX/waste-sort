import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Owns a preview-only capture session for the camera setup page, so the user can aim the
/// camera while the instructions are still on screen. Deliberately separate from the session
/// `LiveCameraView` runs — the two never overlap, because onboarding finishes before it appears.
@MainActor
final class OnboardingCameraModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case running
        case denied
        case unavailable
    }

    @Published private(set) var status: Status = .idle

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "sortla.onboarding.camera")
    private var configuredDeviceID: String?

    func start(preferenceID: String) async {
        guard await requestAccess() else {
            status = .denied
            return
        }

        guard let device = CameraDeviceCatalog.resolveDevice(preferenceID: preferenceID) else {
            status = .unavailable
            return
        }

        if configuredDeviceID != device.uniqueID {
            guard configure(with: device) else {
                status = .unavailable
                return
            }
            configuredDeviceID = device.uniqueID
        }

        let session = session
        sessionQueue.async {
            if !session.isRunning { session.startRunning() }
        }
        status = .running
    }

    func stop() {
        let session = session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
        status = .idle
    }

    private func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private func configure(with device: AVCaptureDevice) -> Bool {
        guard let input = try? AVCaptureDeviceInput(device: device) else { return false }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for existing in session.inputs { session.removeInput(existing) }
        guard session.canAddInput(input) else { return false }
        session.addInput(input)

        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        return true
    }
}

/// Hosts the `AVCaptureVideoPreviewLayer` for `OnboardingCameraModel`.
struct OnboardingCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
    }

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // Safe: `layerClass` guarantees the backing layer's type.
            // swiftlint:disable:next force_cast
            layer as! AVCaptureVideoPreviewLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
    }
}
