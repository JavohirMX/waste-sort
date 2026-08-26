import AVFoundation
import SwiftUI
import UIKit
import UltralyticsYOLO

// MARK: - Camera device, session, and model management

extension LiveCameraCoordinator {
    func startObservingCameraChanges() {
        stopObservingCameraChanges()
        _ = CameraDeviceCatalog.availableOptions()
        let center = NotificationCenter.default
        cameraObservers = [
            center.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.applyPreferredCamera()
            },
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.applyPreferredCamera()
            },
            center.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // YOLOView writes both connections on its camera queue first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.syncInferenceOrientation()
                }
            }
        ]
    }

    func stopObservingCameraChanges() {
        applyWorkItem?.cancel()
        applyWorkItem = nil
        for observer in cameraObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        cameraObservers.removeAll()
    }

    func schedulePreferredCameraApply(retries: Int) {
        applyWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.registerCaptureSessionIfNeeded()
            if self.applyPreferredCamera() {
                self.registerCaptureSessionIfNeeded()
                self.installFrameColorProxyIfNeeded()
                return
            }
            if retries > 0 {
                self.schedulePreferredCameraApply(retries: retries - 1)
            }
        }
        applyWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    @discardableResult
    func applyPreferredCamera() -> Bool {
        guard let view = yoloView,
              let device = CameraDeviceCatalog.resolveDevice(preferenceID: preferredCameraID)
        else {
            return false
        }

        if YOLOViewCameraSwitcher.currentDeviceUniqueID(in: view) == device.uniqueID {
            applyCaptureResolution()
            registerCaptureSessionIfNeeded()
            applyCaptureControlsIfNeeded()
            installFrameColorProxyIfNeeded()
            syncInferenceOrientation()
            return true
        }

        let ok = YOLOViewCameraSwitcher.switchTo(device, in: view)
        if ok {
            applyCaptureResolution(force: true)
            lastAppliedCaptureDeviceID = nil
            registerCaptureSessionIfNeeded()
            applyCaptureControlsIfNeeded()
            installFrameColorProxyIfNeeded()
            syncInferenceOrientation()
        }
        return ok
    }

    private func syncInferenceOrientation() {
        guard let view = yoloView else { return }
        let delta = YOLOViewCameraSwitcher.syncInferenceOrientation(in: view)
        guard lastPresentationDelta != delta else { return }
        lastPresentationDelta = delta
        DispatchQueue.main.async { [weak self] in
            self?.onPresentationDelta?(delta)
        }
    }

    func updateFrameColorControls() {
        frameColorProxy?.controls = currentInputs.settings.frameColor
        frameColorProxy?.syncPreviewLayout()
    }

    func installFrameColorProxyIfNeeded() {
        guard let view = yoloView else { return }
        if frameColorProxy == nil {
            frameColorProxy = VideoFrameColorProxy()
        }
        // The tap copies luma here on the camera queue and detects on the pipeline's own
        // queue. Running the pass inline would cost YOLO an inference frame per detection.
        frameColorProxy?.frameTap = { [weak self] pixelBuffer in
            guard let self else { return }
            let inputs = self.currentInputs
            if inputs.openness.usesMarkers {
                // Marker detection reads chroma, so it has to run on the buffer as the
                // sensor delivered it — before `FrameColorAdjuster` rewrites it below.
                var config = BinMarkerConfig.standard
                config.style = inputs.openness.markerKind.style
                var dashConfig = BinMarkerDashConfig.standard
                dashConfig.profile = inputs.openness.markerDashProfile
                dashConfig.shape = inputs.openness.markerKind.shape
                // After both, which recompute it from what they were measured to need.
                dashConfig.minRuns = BinMarkerDashConfig
                    .runs(forDashes: inputs.openness.markerDashesToOpen)
                self.markerPipeline.apply(config: config, dashConfig: dashConfig,
                                          inks: inputs.openness.markerInks)
                self.markerPipeline.submit(pixelBuffer)
            } else if inputs.aprilTagEnabled {
                self.aprilTagPipeline.submit(pixelBuffer)
            }
            if inputs.settings.barcodeAssistEnabled {
                self.barcodeScanner.submit(pixelBuffer)
            }
        }
        aprilTagPipeline.onTags = { [weak self] tags, timestamp in
            self?.aprilTagBinDetector.ingest(tags: tags, timestamp: timestamp)
        }
        markerPipeline.onDetections = { [weak self] detections, timestamp in
            self?.markerBinDetector.ingest(detections: detections, timestamp: timestamp)
        }
        markerPipeline.onDashRows = { [weak self] rows, timestamp in
            self?.markerBinDetector.ingest(rows: rows, timestamp: timestamp)
        }
        frameColorProxy?.controls = currentInputs.settings.frameColor
        frameColorProxy?.install(on: view)
        frameColorProxy?.syncPreviewLayout()
    }

    func uninstallFrameColorProxy() {
        frameColorProxy?.uninstall()
        frameColorProxy = nil
    }

    /// Raises the session preset to whatever the range profile asks for.
    ///
    /// Set directly on the session rather than through `YOLOView.captureSessionPreset`,
    /// whose setter tears the capture down and restarts it - which would drop the frame
    /// colour proxy and the AprilTag tap along with it.
    func applyCaptureResolution(force: Bool = false) {
        guard let view = yoloView,
              let session = YOLOViewCameraSwitcher.captureSession(in: view)
        else {
            return
        }
        let wanted = aprilTagRangeProfile.captureSessionPresets
        guard force || !wanted.contains(session.sessionPreset) else { return }
        guard let preset = wanted.first(where: { session.canSetSessionPreset($0) }),
              session.sessionPreset != preset
        else {
            return
        }
        session.beginConfiguration()
        session.sessionPreset = preset
        session.commitConfiguration()
    }

    func applyCaptureControlsIfNeeded() {
        guard let view = yoloView,
              let device = YOLOViewCameraSwitcher.currentVideoDevice(in: view)
        else {
            return
        }
        let controls = currentInputs.settings.captureControls
        if lastAppliedCaptureDeviceID == device.uniqueID,
           lastAppliedCaptureControls == controls {
            return
        }
        CameraCaptureAdjuster.apply(controls, to: device)
        lastAppliedCaptureDeviceID = device.uniqueID
        lastAppliedCaptureControls = controls
    }

    func registerCaptureSessionIfNeeded() {
        guard yoloView != nil else { return }
        // Defer so we never publish ObservableObject changes mid-view-update.
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.yoloView else { return }
            self.recording.register(from: view)
        }
    }

    func reloadModel(named name: String) {
        guard let view = yoloView, !isReloadingModel else { return }
        isReloadingModel = true
        zoomRecheck.invalidateModel()
        view.setModel(modelPathOrName: name, task: .segment) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isReloadingModel = false
                if case .success = result {
                    LiveYOLOCamera.applyThresholds(view, settings: self.currentInputs.settings)
                    if self.capturingOriginals {
                        YOLOViewPredictorAccess.setCapturesOriginalImage(true, in: view)
                    }
                    self.applyPreferredCamera()
                    self.registerCaptureSessionIfNeeded()
                    self.applyCaptureControlsIfNeeded()
                    self.installFrameColorProxyIfNeeded()
                }
            }
        }
    }
}
