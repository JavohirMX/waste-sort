import AVFoundation
import Combine
import Foundation
import os
import Photos
import UIKit
import UltralyticsYOLO

enum RecordingPhase: Equatable {
    case idle
    case starting
    case recording
    case stopping
    case saving
}

/// Lock-guarded mirror of `RecordingController.phase`.
///
/// The YOLO inference queue calls into the live pipeline on every frame and must
/// know whether a recording is rolling without hopping to the main actor.
/// This mirror is updated whenever the published phase changes and is safe to
/// read from any thread.
final class RecordingPhaseMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RecordingPhase = .idle

    var current: RecordingPhase {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: RecordingPhase) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

/// Records the live camera feed (no UI overlays) and an overlay-burned twin, plus a CSV log.
@MainActor
final class RecordingController: NSObject, ObservableObject {
    static let shared = RecordingController()

    /// Thread-safe phase mirror for nonisolated readers (camera queue).
    let phaseMirror = RecordingPhaseMirror()

    @Published private(set) var phase: RecordingPhase = .idle {
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

    private weak var captureSession: AVCaptureSession?
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "waste-sort.recording.session")
    private var outputURL: URL?
    private var stopRequested = false
    private var saveWasInterrupted = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var sessionObservers: [NSObjectProtocol] = []
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var autoStartWorkItem: DispatchWorkItem?
    private var suppressAutoStartUntilInactive = false
    private var startGeneration = 0
    private var startingWatchdogItem: DispatchWorkItem?

    private let logStore = DetectionLogStore.shared
    private lazy var recoveryService = RecordingRecoveryService(
        directory: recordingsDirectory,
        activeFileKey: activeFileKey,
        activeAnnotatedFileKey: activeAnnotatedFileKey
    )
    /// Owns the per-session CSV event trail and overlay movie.
    private let sessionLogger = DetectionSessionLogger()
    private var sessionRotation: LivePreviewRotation = WasteSortConfig.defaultLiveRotation
    private var sessionMirror = WasteSortConfig.defaultLiveMirror
    private var annotatedPending = false
    private var logSavedToFiles = false
    private var annotatedSavedToFiles = false
    /// Set when the CSV export failed, so the completion message can be honest about it.
    private var csvFailed = false

    private let activeFileKey = "recording.activeFilePath"
    private let activeAnnotatedFileKey = "recording.activeAnnotatedFilePath"

    private var recordingsDirectory: URL {
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

    private func cancelStartingWatchdog() {
        startingWatchdogItem?.cancel()
        startingWatchdogItem = nil
    }

    private func scheduleAutoStartRetry(retries: Int) {
        guard retries > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.considerAutoStart(retries: retries - 1)
        }
        autoStartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func cancelAutoStart() {
        autoStartWorkItem?.cancel()
        autoStartWorkItem = nil
    }

    private func beginDetectionSession() {
        sessionLogger.begin(
            rotation: sessionRotation,
            mirror: sessionMirror,
            recordingsDirectory: recordingsDirectory,
            persistedAnnotatedKey: activeAnnotatedFileKey
        )
    }

    private func abortDetectionSession() {
        annotatedPending = false
        sessionLogger.abort(persistedAnnotatedKey: activeAnnotatedFileKey)
    }

    private func finishDetectionArtifactsThenSave() {
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

    private func copyAnnotatedToDocuments(_ tempURL: URL, prefix: String) {
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

    private func observeCaptureSession(_ session: AVCaptureSession?) {
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
    private func ensureMovieOutput(on session: AVCaptureSession) -> Bool {
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

    private func makeRecordingURL() -> URL {
        recordingsDirectory.appendingPathComponent("waste-sort-\(UUID().uuidString).mov")
    }

    /// Rotates and optionally mirrors the recorded stream to match the Live preview snapshot.
    private func applyFeedRotation(to connection: AVCaptureConnection, session: AVCaptureSession) {
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

    private func recoverLeftoverRecordings() {
        let files = recoveryService.recoverRawRecordings()
        guard !files.isEmpty else { return }
        saveWasInterrupted = true
        enqueueSaves(files)
    }

    private func recoverLeftoverAnnotatedRecordings() {
        let files = recoveryService.recoverAnnotatedRecordings()
        guard !files.isEmpty else { return }
        for item in files {
            copyAnnotatedToDocuments(item.url, prefix: item.prefix)
        }
        saveWasInterrupted = true
        enqueueSaves(files.map(\.url))
    }

    private func enqueueSaves(_ urls: [URL]) {
        photoSaver.enqueue(urls)
        processSaveQueue()
    }

    private func processSaveQueue() {
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

    private let photoSaver = PhotoLibrarySaver()

    private func completionStatusMessage() -> String {
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
    private func discardSavedClip(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        if url.path == UserDefaults.standard.string(forKey: activeFileKey) {
            UserDefaults.standard.removeObject(forKey: activeFileKey)
        }
        if url.path == UserDefaults.standard.string(forKey: activeAnnotatedFileKey) {
            UserDefaults.standard.removeObject(forKey: activeAnnotatedFileKey)
        }
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SaveRecording") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}

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
