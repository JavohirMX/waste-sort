import Foundation
import os
import Photos

/// Saves finished clips to the user's Photos library, one at a time.
///
/// Extracted from `RecordingController`, which keeps ownership of the phase
/// machine: the controller enqueues URLs, asks for the next save when its phase
/// allows, and reacts to the callbacks below.
@MainActor
final class PhotoLibrarySaver {
    /// User-facing text produced while saving ("Could not save to Photos: …").
    var onStatus: ((String) -> Void)?

    /// The current clip settled successfully or failed - safe to try the next one.
    var onProgress: (() -> Void)?

    /// Photos access is missing; the queue pauses (files stay for a later launch).
    var onPermissionDenied: (() -> Void)?

    /// A clip was imported into Photos; the file at `url` can now be discarded.
    var onSavedFile: ((URL) -> Void)?

    private(set) var pendingURLs: [URL] = []

    var isEmpty: Bool { pendingURLs.isEmpty }

    func enqueue(_ urls: [URL]) {
        pendingURLs.append(contentsOf: urls)
    }

    /// Puts a clip back at the front of the queue without saving it yet.
    func retryLater(_ url: URL) {
        pendingURLs.insert(url, at: 0)
    }

    /// Saves the next queued clip, if any. No-op while a save is in flight.
    func saveNext() {
        guard !pendingURLs.isEmpty else { return }
        let url = pendingURLs.removeFirst()
        saveToPhotos(url: url)
    }

    // MARK: - Private

    private func saveToPhotos(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized || status == .limited else {
                    self.onStatus?("Photos access is required to save recordings.")
                    // Keep the file so a later launch can retry.
                    self.retryLater(url)
                    self.onPermissionDenied?()
                    return
                }

                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = false
                    request.addResource(with: .video, fileURL: url, options: options)
                }) { [weak self] success, error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if success {
                            self.onSavedFile?(url)
                        } else {
                            let detail = error?.localizedDescription ?? "Unknown error"
                            AppLog.recording.error("Photos import failed for \(url.lastPathComponent): \(detail)")
                            self.onStatus?("Could not save to Photos: \(detail)")
                        }
                        self.onProgress?()
                    }
                }
            }
        }
    }
}
