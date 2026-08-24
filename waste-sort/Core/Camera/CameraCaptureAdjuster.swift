import AVFoundation
import Foundation

/// Live camera knobs that change hardware exposure, focus, and white balance.
struct CameraCaptureControls: Equatable {
    var exposureLocked: Bool
    var focusLocked: Bool
    var whiteBalanceLocked: Bool
}

/// Applies capture controls to the current `AVCaptureDevice`. Unsupported knobs are skipped.
enum CameraCaptureAdjuster {
    static func apply(_ controls: CameraCaptureControls, to device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
        } catch {
            return
        }
        defer { device.unlockForConfiguration() }

        applyExposure(controls, to: device)
        applyFocus(controls, to: device)
        applyWhiteBalance(controls, to: device)
    }

    private static func applyExposure(_ controls: CameraCaptureControls, to device: AVCaptureDevice) {
        if controls.exposureLocked {
            if device.isExposureModeSupported(.continuousAutoExposure),
               device.exposureMode != .locked {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }
            return
        }

        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
    }

    private static func applyFocus(_ controls: CameraCaptureControls, to device: AVCaptureDevice) {
        if controls.focusLocked {
            if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            }
            return
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
    }

    private static func applyWhiteBalance(_ controls: CameraCaptureControls, to device: AVCaptureDevice) {
        if controls.whiteBalanceLocked {
            guard device.isWhiteBalanceModeSupported(.locked) else { return }
            var gains = device.deviceWhiteBalanceGains
            let maxGain = device.maxWhiteBalanceGain
            guard gains.redGain >= 1, gains.greenGain >= 1, gains.blueGain >= 1 else {
                device.whiteBalanceMode = .locked
                return
            }
            gains.redGain = min(max(gains.redGain, 1), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1), maxGain)
            gains.blueGain = min(max(gains.blueGain, 1), maxGain)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            return
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }
}
