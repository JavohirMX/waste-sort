import AVFoundation
import Foundation
import Photos
import os
import UIKit

// MARK: - Detection artifacts, recovery, and the Photo-library save queue

extension RecordingController {
    func beginDetectionSession() {
        sessionLogger.begin(
            rotation: sessionRotation,
            mirror: sessionMirror,
            recordingsDirectory: recordingsDirectory,
            persistedAnnotatedKey: activeAnnotatedFileKey
        )
    }

    func abortDetectionSession() {
        annotatedPending = false
        sessionLogger.abort(persistedAnnotatedKey: activeAnnotatedFileKey)
    }

    func finishDetectionArtifactsThenSave() {
        annotatedPending = true
        let result = sessionLogger.finish()
        let csvURL = logStore.finishSession()
        logSavedToFiles = csvURL != nil
        csvFailed = csvURL == nil

        Task { @MainActor in
            if let result {
                let finished = await result.writer.finish()
                if let finished {
                    copyAnnotatedToDocuments(finished, prefix: result.prefix)
                    if recoveryService.usableRecordingURL(finished) != nil {
                        enqueueSaves([finished])
                    }
                }
            }
            UserDefaults.standard.removeObject(forKey: self.activeAnnotatedFileKey)
            annotatedPending = false
            processSaveQueue()
        }
    }

    func copyAnnotatedToDocuments(_ tempURL: URL, prefix: String) {
        let destination = logStore.documentsDirectory.appendingPathComponent("\(prefix)-annotated.mov")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: tempURL, to: destination)
            annotatedSavedToFiles = true
        } catch {
            AppLog.recording.error("Annotated Files copy failed for \(prefix): \(error.localizedDescription)")
            annotatedSavedToFiles = false
        }
    }

    func recoverLeftoverRecordings() {
        let files = recoveryService.recoverRawRecordings()
        guard !files.isEmpty else { return }
        saveWasInterrupted = true
        enqueueSaves(files)
    }

    func recoverLeftoverAnnotatedRecordings() {
        let files = recoveryService.recoverAnnotatedRecordings()
        guard !files.isEmpty else { return }
        for item in files {
            copyAnnotatedToDocuments(item.url, prefix: item.prefix)
        }
        saveWasInterrupted = true
        enqueueSaves(files.map(\.url))
    }

    func enqueueSaves(_ urls: [URL]) {
        photoSaver.enqueue(urls)
        processSaveQueue()
    }

    func processSaveQueue() {
        guard phase != .recording, phase != .starting else { return }
        guard !photoSaver.isEmpty else {
            if annotatedPending { return }
            if phase == .saving || phase == .stopping {
                phase = .idle
                statusMessage = completionStatusMessage()
                saveWasInterrupted = false
            }
            endBackgroundTask()
            return
        }

        beginBackgroundTaskIfNeeded()
        phase = .saving
        statusMessage = "Saving…"
        photoSaver.saveNext()
    }

    func completionStatusMessage() -> String {
        let filesExportOK = logSavedToFiles || annotatedSavedToFiles
        let saved = saveWasInterrupted ? "Saved interrupted recording" : "Saved"
        switch (filesExportOK, csvFailed) {
        case (true, _):
            return "\(saved) to Photos · log saved to Files"
        case (false, true):
            return "\(saved) to Photos · Files export failed (see logs)"
        case (false, false):
            return "\(saved) to Photos"
        }
    }

    /// A clip made it into Photos; drop the local file and forget any persisted
    /// "active recording" pointer that referenced it.
    func discardSavedClip(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        if url.path == UserDefaults.standard.string(forKey: activeFileKey) {
            UserDefaults.standard.removeObject(forKey: activeFileKey)
        }
        if url.path == UserDefaults.standard.string(forKey: activeAnnotatedFileKey) {
            UserDefaults.standard.removeObject(forKey: activeAnnotatedFileKey)
        }
    }

    func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SaveRecording") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
