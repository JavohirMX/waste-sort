import AVFoundation
import Foundation
import UltralyticsYOLO

// MARK: - Auto-start policy (auto-record on open)

extension RecordingController {
    /// Starts recording when auto-record is on, the camera is ready, and the user has not just stopped.
    func considerAutoStart(retries: Int = 20, ignoringManualStop: Bool = false) {
        autoStartWorkItem?.cancel()
        autoStartWorkItem = nil

        if ignoringManualStop {
            suppressAutoStartUntilInactive = false
        }

        guard AppSettings.shared.autoRecordOnOpen else { return }
        guard !suppressAutoStartUntilInactive else { return }

        switch phase {
        case .starting, .recording:
            return
        case .stopping, .saving:
            scheduleAutoStartRetry(retries: retries)
            return
        case .idle:
            break
        }

        guard hasLiveSession, let session = captureSession else {
            scheduleAutoStartRetry(retries: retries)
            return
        }
        guard session.isRunning else {
            scheduleAutoStartRetry(retries: retries)
            return
        }

        startRecording()
    }

    /// Clears the manual-stop suppress so the next foreground can auto-start again.
    func noteSceneBecameInactive() {
        suppressAutoStartUntilInactive = false
        cancelAutoStart()
    }

    func scheduleAutoStartRetry(retries: Int) {
        guard retries > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.considerAutoStart(retries: retries - 1)
        }
        autoStartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func cancelAutoStart() {
        autoStartWorkItem?.cancel()
        autoStartWorkItem = nil
    }
}
