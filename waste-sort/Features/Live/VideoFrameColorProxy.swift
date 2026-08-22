import AVFoundation
import UIKit
import UltralyticsYOLO

/// Intercepts camera frames, applies software color controls in place, then forwards to YOLO.
final class VideoFrameColorProxy: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var _controls = FrameColorControls.identity
    private var _frameTap: ((CVPixelBuffer) -> Void)?
    private weak var videoCapture: VideoCapture?
    private weak var yoloView: YOLOView?
    private weak var videoOutput: AVCaptureVideoDataOutput?
    private weak var nativePreviewLayer: AVCaptureVideoPreviewLayer?
    private var cameraQueue: DispatchQueue?
    private let processedPreviewLayer: CALayer = {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        layer.isHidden = true
        layer.actions = ["contents": NSNull()]
        return layer
    }()
    private var showingProcessedPreview = false

    /// `captureOutput` runs on the camera queue; `uninstall` on the caller's
    /// (main) thread. Guard the shared flag with the same lock as controls.
    private var isShowingProcessedPreview: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return showingProcessedPreview
        }
        set {
            lock.lock()
            showingProcessedPreview = newValue
            lock.unlock()
        }
    }

    var frameTap: ((CVPixelBuffer) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _frameTap
        }
        set {
            lock.lock()
            _frameTap = newValue
            lock.unlock()
        }
    }

    var controls: FrameColorControls {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _controls
        }
        set {
            lock.lock()
            _controls = newValue
            lock.unlock()
        }
    }

    @discardableResult
    func install(on view: YOLOView) -> Bool {
        guard let capture = YOLOViewPredictorAccess.videoCapture(in: view),
              let queue = YOLOViewPredictorAccess.cameraQueue(in: capture),
              let output = YOLOViewPredictorAccess.videoOutput(in: capture)
        else {
            return false
        }

        yoloView = view
        videoCapture = capture
        videoOutput = output
        cameraQueue = queue
        nativePreviewLayer = capture.previewLayer
        attachProcessedLayer(to: view)
        if output.sampleBufferDelegate === self {
            return true
        }
        queue.async { [weak self] in
            guard let self else { return }
            output.setSampleBufferDelegate(self, queue: queue)
        }
        return true
    }

    func uninstall() {
        if let output = videoOutput, let queue = cameraQueue, let capture = videoCapture {
            queue.async {
                output.setSampleBufferDelegate(capture, queue: queue)
            }
        }
        _frameTap = nil
        isShowingProcessedPreview = false
        processedPreviewLayer.removeFromSuperlayer()
        processedPreviewLayer.contents = nil
        processedPreviewLayer.isHidden = true
        nativePreviewLayer?.isHidden = false
        videoCapture = nil
        yoloView = nil
        videoOutput = nil
        cameraQueue = nil
        nativePreviewLayer = nil
    }

    func syncPreviewLayout() {
        guard let view = yoloView else { return }
        processedPreviewLayer.frame = view.bounds
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            frameTap?(pixelBuffer)
            let current = controls.clamped
            if !current.isIdentity {
                FrameColorAdjuster.processInPlace(pixelBuffer, controls: current)
                showProcessedPreview(from: pixelBuffer)
            } else {
                showNativePreview()
            }
        } else {
            showNativePreview()
        }
        videoCapture?.captureOutput(output, didOutput: sampleBuffer, from: connection)
    }

    private func attachProcessedLayer(to view: YOLOView) {
        if processedPreviewLayer.superlayer !== view.layer {
            processedPreviewLayer.removeFromSuperlayer()
            let insertIndex: UInt32
            if let preview = nativePreviewLayer ?? YOLOViewPredictorAccess.videoCapture(in: view)?.previewLayer,
               let previewIndex = view.layer.sublayers?.firstIndex(of: preview) {
                insertIndex = UInt32(previewIndex + 1)
            } else {
                insertIndex = 1
            }
            view.layer.insertSublayer(processedPreviewLayer, at: insertIndex)
        }
        processedPreviewLayer.frame = view.bounds
    }

    private func showProcessedPreview(from pixelBuffer: CVPixelBuffer) {
        guard let cgImage = FrameColorAdjuster.makeCGImage(from: pixelBuffer) else { return }
        if !isShowingProcessedPreview {
            isShowingProcessedPreview = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.nativePreviewLayer?.isHidden = true
                self.processedPreviewLayer.isHidden = false
                self.syncPreviewLayout()
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        processedPreviewLayer.contents = cgImage
        CATransaction.commit()
    }

    private func showNativePreview() {
        guard isShowingProcessedPreview else { return }
        isShowingProcessedPreview = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.processedPreviewLayer.contents = nil
            self.processedPreviewLayer.isHidden = true
            self.nativePreviewLayer?.isHidden = false
        }
    }
}
