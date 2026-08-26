import AVFoundation
import Foundation

extension RecordingController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        Task { @MainActor in
            guard phase == .starting, outputURL?.path == fileURL.path else { return }
            cancelStartingWatchdog()
            outputURL = fileURL
            UserDefaults.standard.set(fileURL.path, forKey: activeFileKey)
            beginDetectionSession()

            if stopRequested {
                phase = .stopping
                statusMessage = "Stopping…"
                sessionQueue.async { [weak self] in
                    self?.movieOutput.stopRecording()
                }
                return
            }

            phase = .recording
            statusMessage = "Recording…"
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            if phase == .starting || phase == .recording,
               let current = outputURL,
               current.path != outputFileURL.path {
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }

            cancelStartingWatchdog()
            outputURL = nil

            if let usable = recoveryService.usableRecordingURL(outputFileURL) {
                finishDetectionArtifactsThenSave()
                enqueueSaves([usable])
                return
            }

            try? FileManager.default.removeItem(at: outputFileURL)
            abortDetectionSession()
            if stopRequested {
                statusMessage = "Recording cancelled."
            } else if let error {
                statusMessage = error.localizedDescription
            } else {
                statusMessage = "Recording file was empty."
            }
            stopRequested = false
            phase = .idle
            endBackgroundTask()
        }
    }
}
