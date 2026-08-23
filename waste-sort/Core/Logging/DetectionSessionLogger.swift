import Foundation
import UIKit

/// Owns one recording session's detection artifacts: the JSONL/CSV event trail
/// and the overlay-burned twin movie.
///
/// Thread safety: `record` runs on the YOLO inference queue once per frame while
/// begin/finish/abort happen on the main thread. All state is guarded by
/// `stateLock`; event appends delegate to `DetectionLogStore`, which serializes
/// its own file access.
final class DetectionSessionLogger {
    private let logStore: DetectionLogStore

    private let stateLock = NSLock()
    private var sessionId: String?
    private var sessionStartedAt: Date?
    private var filePrefix: String?
    private var loggedTrackIDs: Set<Int> = []
    private var lastClassByTrack: [Int: String] = [:]
    private var lastMissesByTrack: [Int: Int] = [:]
    private var annotatedWriter: AnnotatedVideoWriter?

    init(logStore: DetectionLogStore = .shared) {
        self.logStore = logStore
    }

    /// Begins a new session; returns the shared file prefix for output naming.
    @discardableResult
    func begin(
        rotation: LivePreviewRotation,
        mirror: Bool,
        recordingsDirectory: URL,
        persistedAnnotatedKey: String
    ) -> String {
        let startedAt = Date()
        let id = UUID().uuidString
        let prefix = SessionFileNamer.prefix(for: startedAt)

        stateLock.lock()
        sessionId = id
        sessionStartedAt = startedAt
        filePrefix = prefix
        loggedTrackIDs.removeAll()
        lastClassByTrack.removeAll()
        lastMissesByTrack.removeAll()

        let annotatedURL = recordingsDirectory.appendingPathComponent("\(prefix)-annotated.mov")
        try? FileManager.default.removeItem(at: annotatedURL)
        let writer = AnnotatedVideoWriter(
            outputURL: annotatedURL,
            rotation: rotation,
            mirror: mirror
        )
        annotatedWriter = writer
        stateLock.unlock()

        logStore.startSession(id: id, startedAt: startedAt, filePrefix: prefix)
        UserDefaults.standard.set(annotatedURL.path, forKey: persistedAnnotatedKey)
        return prefix
    }

    /// Logs track lifecycle events and zone deposits, and feeds the overlay movie.
    /// Called on the YOLO inference queue.
    func record(
        tracks: [TrackedDetection],
        deposits: [ZoneDeposit],
        originalImage: UIImage?,
        fps: Int,
        settings: RuntimeSettings
    ) {
        stateLock.lock()
        guard let sessionId, let sessionStartedAt else {
            stateLock.unlock()
            return
        }
        let now = Date()
        var events: [DetectionLogEvent] = []

        for track in tracks {
            let isNew = loggedTrackIDs.insert(track.id).inserted
            let previousClass = lastClassByTrack[track.id]
            let previousMisses = lastMissesByTrack[track.id] ?? 0
            lastClassByTrack[track.id] = track.classKey
            lastMissesByTrack[track.id] = track.misses

            if isNew {
                events.append(
                    Self.event(
                        now: now,
                        sessionId: sessionId,
                        sessionStartedAt: sessionStartedAt,
                        track: track,
                        fps: fps,
                        settings: settings,
                        eventType: DetectionLogEvent.eventTypeFirstSeen
                    )
                )
            } else if previousClass != track.classKey {
                events.append(
                    Self.event(
                        now: now,
                        sessionId: sessionId,
                        sessionStartedAt: sessionStartedAt,
                        track: track,
                        fps: fps,
                        settings: settings,
                        eventType: DetectionLogEvent.eventTypeClassSwitch
                    )
                )
            }

            if track.misses == 1, previousMisses == 0 {
                events.append(
                    Self.event(
                        now: now,
                        sessionId: sessionId,
                        sessionStartedAt: sessionStartedAt,
                        track: track,
                        fps: fps,
                        settings: settings,
                        eventType: DetectionLogEvent.eventTypeCoastStart
                    )
                )
            }
        }

        for deposit in deposits {
            let bin = BinGuide.info(for: deposit.classKey)
            events.append(
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
                    dwellFrames: deposit.dwellFrames,
                    viaTrajectory: deposit.viaTrajectory,
                    beliefUncertain: deposit.wasUncertain,
                    beliefMargin: Double(deposit.margin),
                    modelTopClassKey: deposit.modelTopClassKey.isEmpty ? nil : deposit.modelTopClassKey
                )
            )
        }
        let writer = annotatedWriter
        stateLock.unlock()

        for event in events {
            logStore.append(event)
        }
        if let originalImage {
            writer?.append(image: originalImage, tracks: tracks, timestamp: now)
        }
    }

    struct FinishResult {
        /// Overlay movie writer ready for async finalization.
        let writer: AnnotatedVideoWriter
        /// Shared session file prefix, e.g. `Sortla-2026-08-14-150932`.
        let prefix: String
    }

    /// Finishes the CSV (writes Documents export) and returns the overlay writer
    /// plus session prefix for finalization. Nil when no session was active.
    func finish() -> FinishResult? {
        stateLock.lock()
        guard let prefix = filePrefix, let writer = annotatedWriter else {
            stateLock.unlock()
            return nil
        }
        clearIdentifiersLocked()
        annotatedWriter = nil
        stateLock.unlock()
        logStore.finishSession()
        return FinishResult(writer: writer, prefix: prefix)
    }

    /// Drops the in-progress session without exporting anything.
    func abort(persistedAnnotatedKey: String) {
        stateLock.lock()
        if let writer = annotatedWriter {
            writer.cancel()
        }
        annotatedWriter = nil
        clearIdentifiersLocked()
        stateLock.unlock()
        logStore.discardSession()
        UserDefaults.standard.removeObject(forKey: persistedAnnotatedKey)
    }

    // MARK: - Private

    private func clearIdentifiersLocked() {
        sessionId = nil
        sessionStartedAt = nil
        filePrefix = nil
        loggedTrackIDs.removeAll()
        lastClassByTrack.removeAll()
        lastMissesByTrack.removeAll()
    }

    private static func event(
        now: Date,
        sessionId: String,
        sessionStartedAt: Date,
        track: TrackedDetection,
        fps: Int,
        settings: RuntimeSettings,
        eventType: String
    ) -> DetectionLogEvent {
        let bin = BinGuide.info(for: track.classKey)
        return DetectionLogEvent(
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
            eventType: eventType,
            rawClassKey: track.observedClassKey,
            beliefUncertain: track.beliefUncertain,
            beliefMargin: Double(track.beliefMargin)
        )
    }
}
