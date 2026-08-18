import AVFoundation
import Combine
import Foundation
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

/// Records the live camera feed (no UI overlays) and an overlay-burned twin, plus a CSV log.
@MainActor
final class RecordingController: NSObject, ObservableObject {
    static let shared = RecordingController()

    @Published private(set) var phase: RecordingPhase = .idle
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
    private var pendingSaveURLs: [URL] = []
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var sessionObservers: [NSObjectProtocol] = []
    private var lifecycleObservers: [NSObjectProtocol] = []

    private let logStore = DetectionLogStore.shared
    private var annotatedWriter: AnnotatedVideoWriter?
    private var sessionId: String?
    private var sessionStartedAt: Date?
    private var filePrefix: String?
    private var loggedTrackIDs = Set<Int>()
    private var sessionRotation: LivePreviewRotation = WasteSortConfig.defaultLiveRotation
    private var sessionMirror = WasteSortConfig.defaultLiveMirror
    private var annotatedPending = false
    private var logSavedToFiles = false
    private var annotatedSavedToFiles = false

    private let activeFileKey = "recording.activeFilePath"
    private let activeAnnotatedFileKey = "recording.activeAnnotatedFilePath"

    private var recordingsDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("Recordings", isDirectory: true)
    }

    private override init() {
        super.init()
        movieOutput.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)

        lifecycleObservers = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.flushAndSave()
            },
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
        if session == nil, canStop || phase == .stopping {
            flushAndSave()
        }
    }

    func register(from view: YOLOView) {
        register(session: YOLOViewCameraSwitcher.captureSession(in: view))
    }

    func ingestLiveFrame(
        tracks: [TrackedDetection],
        deposits: [ZoneDeposit],
        zones: [DropZone],
        originalImage: UIImage?,
        fps: Int,
        settings: RuntimeSettings
    ) {
        guard isRecording, let sessionId, let sessionStartedAt else { return }

        let now = Date()
        for track in tracks where loggedTrackIDs.insert(track.id).inserted {
            let bin = BinGuide.info(for: track.classKey)
            logStore.append(
                DetectionLogEvent(
                    timestamp: now,
                    sessionId: sessionId,
                    sessionStartedAt: sessionStartedAt,
                    trackId: track.id,
                    classKey: track.classKey,
                    className: track.className,
                    bin: bin.id,
                    confidence: Double(track.conf),
                    model: settings.selectedModelName,
                    confidenceThreshold: settings.confidence,
                    iouThreshold: settings.iou,
                    cameraId: settings.preferredCameraID,
                    boxX: Double(track.displayXywhn.origin.x),
                    boxY: Double(track.displayXywhn.origin.y),
                    boxW: Double(track.displayXywhn.width),
                    boxH: Double(track.displayXywhn.height),
                    fps: fps,
                    eventType: DetectionLogEvent.eventTypeFirstSeen
                )
            )
        }

        for deposit in deposits {
            let bin = BinGuide.info(for: deposit.classKey)
            logStore.append(
                DetectionLogEvent(
                    timestamp: now,
                    sessionId: sessionId,
                    sessionStartedAt: sessionStartedAt,
                    trackId: deposit.trackID,
                    classKey: deposit.classKey,
                    className: deposit.className,
                    bin: bin.id,
                    confidence: Double(deposit.conf),
                    model: settings.selectedModelName,
                    confidenceThreshold: settings.confidence,
                    iouThreshold: settings.iou,
                    cameraId: settings.preferredCameraID,
                    boxX: Double(deposit.boxXywhn.origin.x),
                    boxY: Double(deposit.boxXywhn.origin.y),
                    boxW: Double(deposit.boxXywhn.width),
                    boxH: Double(deposit.boxXywhn.height),
                    fps: fps,
                    eventType: DetectionLogEvent.eventTypeZoneDeposit,
                    zoneId: deposit.zoneID.uuidString,
                    zoneName: deposit.zoneName,
                    zoneBin: deposit.zoneBinID,
                    isCorrect: deposit.isCorrect,
                    dwellFrames: deposit.dwellFrames
                )
            )
        }

        if let originalImage {
            annotatedWriter?.append(
                image: originalImage,
                tracks: tracks,
                zones: zones,
                timestamp: now
            )
        }
    }

    func startRecording() {
        guard canStart else { return }
        guard let session = captureSession else {
            statusMessage = "Open the Live tab first."
            return
        }

        stopRequested = false
        saveWasInterrupted = false
        logSavedToFiles = false
        annotatedSavedToFiles = false
        sessionRotation = AppSettings.shared.liveRotation
        sessionMirror = AppSettings.shared.liveMirror
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

            guard self.ensureMovieOutput(on: session) else {
                DispatchQueue.main.async {
                    self.failStart("Could not attach video recorder to the camera.")
                }
                return
            }

            let url = self.makeRecordingURL()
            try? FileManager.default.removeItem(at: url)

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

            DispatchQueue.main.async {
                self.outputURL = url
                UserDefaults.standard.set(url.path, forKey: self.activeFileKey)
            }

            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        switch phase {
        case .idle, .stopping, .saving:
            return
        case .starting, .recording:
            break
        }

        stopRequested = true
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
        abortDetectionSession()
        phase = .idle
        outputURL = nil
        UserDefaults.standard.removeObject(forKey: activeFileKey)
        statusMessage = stopRequested ? "Recording cancelled." : message
        stopRequested = false
        endBackgroundTask()
    }

    private func beginDetectionSession() {
        let startedAt = Date()
        let id = UUID().uuidString
        let prefix = SessionFileNamer.prefix(for: startedAt)
        sessionId = id
        sessionStartedAt = startedAt
        filePrefix = prefix
        loggedTrackIDs.removeAll()
        logSavedToFiles = false
        annotatedSavedToFiles = false
        logStore.startSession(id: id, startedAt: startedAt, filePrefix: prefix)

        let annotatedURL = recordingsDirectory.appendingPathComponent("\(prefix)-annotated.mov")
        try? FileManager.default.removeItem(at: annotatedURL)
        annotatedWriter = AnnotatedVideoWriter(
            outputURL: annotatedURL,
            rotation: sessionRotation,
            mirror: sessionMirror
        )
        UserDefaults.standard.set(annotatedURL.path, forKey: activeAnnotatedFileKey)
    }

    private func abortDetectionSession() {
        annotatedWriter?.cancel()
        annotatedWriter = nil
        annotatedPending = false
        logStore.discardSession()
        clearSessionIdentifiers()
        UserDefaults.standard.removeObject(forKey: activeAnnotatedFileKey)
    }

    private func finishDetectionArtifactsThenSave() {
        annotatedPending = true
        let writer = annotatedWriter
        annotatedWriter = nil
        let prefix = filePrefix
        let csvURL = logStore.finishSession()
        logSavedToFiles = csvURL != nil
        clearSessionIdentifiers()

        Task { @MainActor in
            let finished = await writer?.finish()
            if let finished, let prefix {
                copyAnnotatedToDocuments(finished, prefix: prefix)
                if usableRecordingURL(finished) != nil {
                    enqueueSaves([finished])
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
            annotatedSavedToFiles = false
        }
    }

    private func clearSessionIdentifiers() {
        sessionId = nil
        sessionStartedAt = nil
        filePrefix = nil
        loggedTrackIDs.removeAll()
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
            },
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
        let baseAngle: CGFloat
        if let dataOut = session.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }).first,
           let dataConn = dataOut.connection(with: .video)
        {
            baseAngle = dataConn.videoRotationAngle
        } else {
            baseAngle = 0
        }

        var target = (baseAngle + CGFloat(sessionRotation.rawValue)).truncatingRemainder(dividingBy: 360)
        if target < 0 { target += 360 }
        if connection.isVideoRotationAngleSupported(target) {
            connection.videoRotationAngle = target
        } else {
            applyLegacyOrientation(to: connection, session: session)
        }

        guard connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        let isFront = session.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first { $0.device.hasMediaType(.video) }?
            .device.position == .front
        connection.isVideoMirrored = (isFront == true) != sessionMirror
    }

    private func applyLegacyOrientation(to connection: AVCaptureConnection, session: AVCaptureSession) {
        let baseOrientation = session.outputs
            .compactMap { $0 as? AVCaptureVideoDataOutput }
            .first?
            .connection(with: .video)?
            .videoOrientation ?? .portrait

        let flipped180: AVCaptureVideoOrientation
        switch baseOrientation {
        case .portrait: flipped180 = .portraitUpsideDown
        case .portraitUpsideDown: flipped180 = .portrait
        case .landscapeRight: flipped180 = .landscapeLeft
        case .landscapeLeft: flipped180 = .landscapeRight
        @unknown default: flipped180 = baseOrientation
        }

        switch sessionRotation {
        case .zero:
            connection.videoOrientation = baseOrientation
        case .oneEighty:
            connection.videoOrientation = flipped180
        case .ninety, .twoSeventy:
            connection.videoOrientation = flipped180
        }
    }

    private func recoverLeftoverRecordings() {
        let files = leftoverRecordingFiles()
        guard !files.isEmpty else {
            UserDefaults.standard.removeObject(forKey: activeFileKey)
            return
        }
        saveWasInterrupted = true
        enqueueSaves(files)
    }

    private func recoverLeftoverAnnotatedRecordings() {
        let files = leftoverAnnotatedFiles()
        guard !files.isEmpty else {
            UserDefaults.standard.removeObject(forKey: activeAnnotatedFileKey)
            return
        }
        for url in files {
            let prefix = url.deletingPathExtension().lastPathComponent.replacingOccurrences(
                of: "-annotated",
                with: ""
            )
            copyAnnotatedToDocuments(url, prefix: prefix)
        }
        saveWasInterrupted = true
        enqueueSaves(files)
    }

    private func leftoverRecordingFiles() -> [URL] {
        leftoverMovies { url in
            !url.lastPathComponent.lowercased().contains("annotated")
        }
    }

    private func leftoverAnnotatedFiles() -> [URL] {
        leftoverMovies { url in
            url.lastPathComponent.lowercased().contains("annotated")
        }
    }

    private func leftoverMovies(matching: (URL) -> Bool) -> [URL] {
        let fm = FileManager.default
        let listed = (try? fm.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var urls = listed.filter {
            $0.pathExtension.lowercased() == "mov" && matching($0)
        }

        let persistedKeys = [activeFileKey, activeAnnotatedFileKey]
        for key in persistedKeys {
            if let path = UserDefaults.standard.string(forKey: key) {
                let persisted = URL(fileURLWithPath: path)
                if matching(persisted),
                   fm.fileExists(atPath: persisted.path),
                   !urls.contains(where: { $0.path == persisted.path })
                {
                    urls.append(persisted)
                }
            }
        }

        var usable: [URL] = []
        for url in urls {
            if usableRecordingURL(url) != nil {
                usable.append(url)
            } else {
                try? fm.removeItem(at: url)
            }
        }
        return usable
    }

    private func usableRecordingURL(_ url: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? NSNumber,
            size.intValue >= 1024
        else {
            return nil
        }
        return url
    }

    private func enqueueSaves(_ urls: [URL]) {
        pendingSaveURLs.append(contentsOf: urls)
        processSaveQueue()
    }

    private func processSaveQueue() {
        guard phase != .recording, phase != .starting else { return }
        guard !pendingSaveURLs.isEmpty else {
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
        let url = pendingSaveURLs.removeFirst()
        statusMessage = "Saving…"
        saveToPhotos(url: url)
    }

    private func completionStatusMessage() -> String {
        if logSavedToFiles || annotatedSavedToFiles {
            return saveWasInterrupted
                ? "Saved interrupted recording to Photos · log saved to Files"
                : "Saved to Photos · log saved to Files"
        }
        return saveWasInterrupted
            ? "Saved interrupted recording to Photos"
            : "Saved to Photos"
    }

    private func saveToPhotos(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.statusMessage = "Photos access is required to save recordings."
                    // Keep the file so a later launch can retry.
                    self.pendingSaveURLs.insert(url, at: 0)
                    self.phase = .idle
                    self.endBackgroundTask()
                }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .video, fileURL: url, options: options)
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        try? FileManager.default.removeItem(at: url)
                        if url.path == UserDefaults.standard.string(forKey: self.activeFileKey) {
                            UserDefaults.standard.removeObject(forKey: self.activeFileKey)
                        }
                        if url.path == UserDefaults.standard.string(forKey: self.activeAnnotatedFileKey) {
                            UserDefaults.standard.removeObject(forKey: self.activeAnnotatedFileKey)
                        }
                    } else {
                        let detail = error?.localizedDescription ?? "Unknown error"
                        self.statusMessage = "Could not save to Photos: \(detail)"
                    }
                    self.processSaveQueue()
                }
            }
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
            outputURL = nil

            if let usable = usableRecordingURL(outputFileURL) {
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
