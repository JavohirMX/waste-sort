import AVFoundation
import Combine
import Foundation
import os
import Photos
import UIKit
import UltralyticsYOLO

/// Records the live camera feed (no UI overlays) and an overlay-burned twin, plus a CSV log.
@MainActor
final class RecordingController: NSObject, ObservableObject {
    static let shared = RecordingController()

    /// Thread-safe phase mirror for nonisolated readers (camera queue).
    let phaseMirror = RecordingPhaseMirror()

    @Published var phase: RecordingPhase = .idle {
        didSet { phaseMirror.set(phase) }
    }
    @Published private(set) var hasLiveSession = false
    @Published var statusMessage: String?

    /// True only after AVFoundation has actually started writing.
    var isRecording: Bool { phase == .recording }

    var canStart: Bool { hasLiveSession && phase == .idle }

    var canStop: Bool { phase == .starting || phase == .recording }

    /// YOLO should copy camera frames while a session is starting, rolling, or stopping.
    var shouldCaptureOriginalFrames: Bool {
        switch phase {
        case .starting, .recording, .stopping:
            return true
        case .idle, .saving:
            return false
        }
    }

    weak var captureSession: AVCaptureSession?
    let movieOutput = AVCaptureMovieFileOutput()
    let sessionQueue = DispatchQueue(label: "waste-sort.recording.session")
    var outputURL: URL?
    var stopRequested = false
    var saveWasInterrupted = false
    var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    var sessionObservers: [NSObjectProtocol] = []
    private var lifecycleObservers: [NSObjectProtocol] = []
    var autoStartWorkItem: DispatchWorkItem?
    var suppressAutoStartUntilInactive = false
    var startGeneration = 0
    var startingWatchdogItem: DispatchWorkItem?

    let logStore = DetectionLogStore.shared
    lazy var recoveryService = RecordingRecoveryService(
        directory: recordingsDirectory,
        activeFileKey: activeFileKey,
        activeAnnotatedFileKey: activeAnnotatedFileKey
    )
    /// Owns the per-session CSV event trail and overlay movie.
    let sessionLogger = DetectionSessionLogger()
    var sessionRotation: LivePreviewRotation = WasteSortConfig.defaultLiveRotation
    var sessionMirror = WasteSortConfig.defaultLiveMirror
    var annotatedPending = false
    var logSavedToFiles = false
    var annotatedSavedToFiles = false
    /// Set when the CSV export failed, so the completion message can be honest about it.
    var csvFailed = false

    /// Saves clips to Photos; its completion callbacks drive the save queue.
    let photoSaver = PhotoLibrarySaver()

    let activeFileKey = "recording.activeFilePath"
    let activeAnnotatedFileKey = "recording.activeAnnotatedFilePath"

    var recordingsDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("Recordings", isDirectory: true)
    }

    private override init() {
        super.init()
        movieOutput.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        do {
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        } catch {
            AppLog.recording.error("Recordings directory create failed: \(error.localizedDescription)")
        }

        photoSaver.onStatus = { [weak self] message in
            self?.statusMessage = message
        }
        photoSaver.onProgress = { [weak self] in
            self?.processSaveQueue()
        }
        photoSaver.onPermissionDenied = { [weak self] in
            self?.phase = .idle
            self?.endBackgroundTask()
        }
        photoSaver.onSavedFile = { [weak self] url in
            self?.discardSavedClip(url)
        }

        lifecycleObservers = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.flushAndSave()
            }
        ]

        _ = logStore.recoverLeftoverSessions()
        recoverLeftoverAnnotatedRecordings()
        recoverLeftoverRecordings()
    }

    func register(session: AVCaptureSession?) {
        if captureSession === session, hasLiveSession == (session != nil) {
            return
        }
        captureSession = session
        let nextHasSession = session != nil
        if hasLiveSession != nextHasSession {
            hasLiveSession = nextHasSession
        }
        observeCaptureSession(session)
        if session == nil {
            cancelAutoStart()
            if canStop || phase == .stopping {
                flushAndSave()
            }
        } else {
            considerAutoStart()
        }
    }

    func register(from view: YOLOView) {
        register(session: YOLOViewCameraSwitcher.captureSession(in: view))
    }

    func ingestLiveFrame(
        tracks: [TrackedDetection],
        deposits: [ZoneDeposit],
        originalImage: UIImage?,
        fps: Int,
        settings: RuntimeSettings
    ) {
        guard isRecording else { return }
        sessionLogger.record(
            tracks: tracks,
            deposits: deposits,
            originalImage: originalImage,
            fps: fps,
            settings: settings
        )
    }
    func startRecording() {
        startRecording(isRetry: false)
    }

    private func startRecording(isRetry: Bool) {
        guard canStart else { return }
        guard let session = captureSession else {
            statusMessage = "The live camera must be running before recording."
            return
        }

        stopRequested = false
        saveWasInterrupted = false
        logSavedToFiles = false
        annotatedSavedToFiles = false
        csvFailed = false
        sessionRotation = AppSettings.shared.liveRotation
        sessionMirror = AppSettings.shared.liveMirror
        startGeneration += 1
        let generation = startGeneration
        phase = .starting
        statusMessage = "Starting…"

        sessionQueue.async { [weak self] in
            guard let self else { return }

            guard session.isRunning else {
                DispatchQueue.main.async {
                    self.failStart("Camera is not running yet. Try again in a moment.")
                }
                return
            }

            let needsSettle = !session.outputs.contains(where: { $0 === self.movieOutput })
            guard self.ensureMovieOutput(on: session) else {
                DispatchQueue.main.async {
                    self.failStart("Could not attach video recorder to the camera.")
                }
                return
            }

            if needsSettle {
                self.sessionQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.beginMovieFileRecording(session: session, generation: generation, isRetry: isRetry)
                }
            } else {
                self.beginMovieFileRecording(session: session, generation: generation, isRetry: isRetry)
            }
        }
    }

    private func beginMovieFileRecording(
        session: AVCaptureSession,
        generation: Int,
        isRetry: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.startGeneration == generation, self.phase == .starting else { return }

            let url = self.makeRecordingURL()
            try? FileManager.default.removeItem(at: url)
            self.outputURL = url
            UserDefaults.standard.set(url.path, forKey: self.activeFileKey)

            self.sessionQueue.async { [weak self] in
                guard let self else { return }
                guard self.movieOutput.connection(with: .video) != nil else {
                    DispatchQueue.main.async {
                        self.failStart("Could not connect video for recording.")
                    }
                    return
                }

                if let audio = self.movieOutput.connection(with: .audio) {
                    audio.isEnabled = false
                }
                if let video = self.movieOutput.connection(with: .video) {
                    self.applyFeedRotation(to: video, session: session)
                }

                self.movieOutput.startRecording(to: url, recordingDelegate: self)
                DispatchQueue.main.async {
                    self.scheduleStartingWatchdog(generation: generation, isRetry: isRetry)
                }
            }
        }
    }

    func stopRecording(userInitiated: Bool = false) {
        if userInitiated {
            suppressAutoStartUntilInactive = true
            cancelAutoStart()
        }

        switch phase {
        case .idle, .stopping, .saving:
            return
        case .starting, .recording:
            break
        }

        stopRequested = true
        cancelStartingWatchdog()
        beginBackgroundTaskIfNeeded()
        phase = .stopping
        statusMessage = "Stopping…"

        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
                return
            }
            // Start may still be in flight; didStartRecording will stop.
            // If AVFoundation never starts, don't stay stuck in .stopping.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.phase == .stopping, !self.movieOutput.isRecording else { return }
                if let url = self.outputURL {
                    try? FileManager.default.removeItem(at: url)
                }
                self.failStart("Recording cancelled.")
            }
        }
    }

    /// Stop and save if a clip is in progress (background, interrupt, Live teardown).
    func flushAndSave() {
        switch phase {
        case .idle:
            return
        case .stopping, .saving:
            beginBackgroundTaskIfNeeded()
            return
        case .starting, .recording:
            saveWasInterrupted = true
            stopRecording()
        }
    }

    private func failStart(_ message: String) {
        cancelStartingWatchdog()
        abortDetectionSession()
        phase = .idle
        outputURL = nil
        UserDefaults.standard.removeObject(forKey: activeFileKey)
        statusMessage = stopRequested ? "Recording cancelled." : message
        stopRequested = false
        endBackgroundTask()
    }

    private func scheduleStartingWatchdog(generation: Int, isRetry: Bool) {
        cancelStartingWatchdog()
        let work = DispatchWorkItem { [weak self] in
            self?.handleStartingTimeout(generation: generation, isRetry: isRetry)
        }
        startingWatchdogItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func handleStartingTimeout(generation: Int, isRetry: Bool) {
        guard startGeneration == generation, phase == .starting else { return }
        guard !movieOutput.isRecording else { return }

        if isRetry {
            failStart("Could not start recording. Try again.")
            return
        }

        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        outputURL = nil
        UserDefaults.standard.removeObject(forKey: activeFileKey)
        phase = .idle
        startRecording(isRetry: true)
    }

    func cancelStartingWatchdog() {
        startingWatchdogItem?.cancel()
        startingWatchdogItem = nil
    }
}
