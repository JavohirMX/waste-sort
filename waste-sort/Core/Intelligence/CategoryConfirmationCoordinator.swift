import CoreGraphics
import Foundation

/// Puts a Foundation-model verdict on top of the detector's own label, and keeps it there.
///
/// The detector never stops running: YOLO plus `DetectionTracker` decide what is on screen
/// and where. This layer only answers a narrower question — *what is it* — and once the
/// model has answered for an item, that answer is locked. YOLO can flip its mind as often as
/// it likes afterwards; the item keeps the category it was confirmed as for as long as it
/// stays on screen.
///
/// Three things make that promise hold in practice:
///
/// - **Serialised requests.** The on-device model handles one prompt at a time and takes
///   roughly a second per image, so requests queue. The largest eligible box goes first,
///   because that is the item somebody is holding up rather than something lying in a bin.
/// - **A verdict outlives a blink.** When the tracker drops an id, the verdict is parked for
///   `lostGrace` and re-adopted by a new track that appears where the old one was. Without
///   this, a momentary dropout would silently unlock the category and the label would snap
///   back to whatever YOLO currently thinks.
/// - **A bounded number of attempts.** An item the model refuses to name is asked again
///   after `retryDelay`, at most `maximumAttempts` times, and then left alone.
nonisolated final class CategoryConfirmationCoordinator: @unchecked Sendable {
    /// Off means fully transparent: tracks pass through untouched and nothing is queued.
    var isEnabled = false
    /// Shortest box side, in normalized image widths, worth cropping and sending.
    var minimumBoxSide: CGFloat = 0.05
    /// Shortest crop side in real pixels. The normalized bar above says nothing about how
    /// much detail there actually is — the same box is 96px at 720p and 288px at 4K — and a
    /// thumbnail-sized crop is not worth a second of the model's time.
    var minimumCropPixels = 96
    /// How many frames of an item are looked at before one is sent.
    ///
    /// Somebody carrying an item past a camera produces mostly smeared frames and a few
    /// clean ones. Sending whichever frame happened to be current when the slot opened is a
    /// coin toss, so a short burst is measured and the sharpest one goes.
    var candidateFrames = 6
    /// Detected frames a track needs before it is asked about, so the model is not handed a
    /// box that is still settling.
    var minimumTrackFrames = 3
    /// How long a verdict waits to be re-adopted after its track disappears. A shade longer
    /// than `ZoneDepositDetector.reacquireGrace`, so this layer never gives up on an item
    /// the deposit layer still considers the same object.
    var lostGrace: CFAbsoluteTime = 1.5
    /// How far a new track may appear from where the lost one was and still inherit it, at
    /// the instant it vanishes.
    var readoptRadius: CGFloat = 0.10
    /// Extra search radius per second missing. An item is usually lost *while being carried*,
    /// so where it reappears depends on how long it was gone — a fixed radius drops exactly
    /// the verdicts worth keeping. Matched to `ZoneDepositDetector` so the two layers agree
    /// on what counts as the same item.
    var readoptDriftPerSecond: CGFloat = 0.55
    /// Ceiling, so a long dropout cannot claim a box on the far side of the frame.
    var readoptMaxRadius: CGFloat = 0.35
    /// Pause before asking again about an item the model declined to name.
    var retryDelay: CFAbsoluteTime = 2.0
    /// Total asks per item before giving up on it.
    var maximumAttempts = 3
    /// Below this the model was hedging, and a hedge is not worth locking in. The reading is
    /// still recorded, so the debug log shows the near misses rather than swallowing them.
    var minimumConfidence = 0.5
    /// Dirty recyclable is allowed to lock on a moderate dirt guess — about 40–50% sure
    /// is enough, so this bar sits below the others.
    var minimumDirtyRecyclableConfidence = 0.4
    /// How long a request may be outstanding before the slot is taken back. A model that
    /// wedges would otherwise stall the whole layer silently and for good.
    var requestTimeout: CFAbsoluteTime = 20
    /// Fraction of the box added on each side, so the model sees some context.
    var cropPadding: CGFloat = 0.15
    /// Longest side of the crop handed to the model. Bigger is slower, not better.
    var cropMaximumSide = 448
    /// Longest side of the copy kept for the debug log.
    var thumbnailMaximumSide = 96

    /// Injected so tests can advance time without sleeping.
    var clock: @Sendable () -> CFAbsoluteTime = { CFAbsoluteTimeGetCurrent() }
    /// How a queued request is run. Injected so tests can drive it deterministically
    /// instead of racing a detached task.
    var dispatch: @Sendable (@escaping @Sendable () async -> Void) -> Void = { work in
        Task(priority: .utility) { await work() }
    }

    let service: CategoryConfirming
    let lock = NSLock()

    final class Entry {
        /// Frames the model actually saw this track — coasting frames do not count.
        var frames = 0
        var verdict: ConfirmedCategory?
        var attempts = 0
        var nextAttemptAt: CFAbsoluteTime = 0
        var isInFlight = false
        var center: CGPoint = .zero

        init(center: CGPoint) {
            self.center = center
        }
    }

    /// A verdict whose track has gone, waiting to be claimed by whatever comes back.
    struct Orphan {
        let verdict: ConfirmedCategory
        let center: CGPoint
        let lostAt: CFAbsoluteTime
    }

    var entries: [Int: Entry] = [:]
    var orphans: [Orphan] = []
    /// Finished readings waiting to be handed out. They ride the caller's existing hop to
    /// the main thread rather than opening a second path of their own.
    var pendingRecords: [FoundationVerdictRecord] = []
    /// The single outstanding request, if any. Held as the track it belongs to rather than a
    /// bare flag so a late answer cannot free a slot that has since been handed to somebody
    /// else.
    var inFlight: (trackID: Int, startedAt: CFAbsoluteTime)?

    /// One measured look at an item.
    struct Candidate {
        let crop: CGImage
        let sharpness: Double
        let detectorClassKey: String
    }

    /// The burst of frames currently being measured, before anything is sent.
    struct Gathering {
        let trackID: Int
        var samples = 0
        var best: Candidate?
    }

    var gathering: Gathering?

    init(service: CategoryConfirming) {
        self.service = service
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
        orphans.removeAll(keepingCapacity: true)
        // A request already with the model is left to land on a track that no longer
        // exists, where `finish` drops it.
        inFlight = nil
        gathering = nil
    }

    /// Folds locked verdicts into this frame's tracks and queues the next question.
    ///
    /// - Parameter frameImage: the full camera frame, fetched lazily because it is only
    ///   needed on the frames where a request is actually sent.
    /// - Returns: the tracks with any locked category applied, the per-track state the
    ///   overlay draws, and any readings that came back since the last call.
    func update(
        tracks: [TrackedDetection],
        frameImage: () -> CGImage?,
        timestamp: CFAbsoluteTime? = nil
    ) -> (tracks: [TrackedDetection], frame: ConfirmationFrame, records: [FoundationVerdictRecord]) {
        let now = timestamp ?? clock()

        lock.lock()

        guard isEnabled else {
            let hadState = !entries.isEmpty || !orphans.isEmpty
            if hadState {
                entries.removeAll(keepingCapacity: true)
                orphans.removeAll(keepingCapacity: true)
            }
            let records = drainRecords()
            lock.unlock()
            return (tracks, ConfirmationFrame(), records)
        }

        retireVanishedTracks(stillPresent: Set(tracks.map(\.id)), at: now)
        orphans.removeAll { now - $0.lostAt > lostGrace }

        for track in tracks {
            let center = CGPoint(x: track.displayXywhn.midX, y: track.displayXywhn.midY)
            let entry = entries[track.id] ?? adopt(trackID: track.id, center: center, at: now)
            entry.center = center
            // Only frames the model really saw count towards steadiness; a frozen box is
            // not evidence that the item is still sitting there.
            if !track.isCoasting {
                entry.frames += 1
            }
        }

        let plan = planSample(tracks: tracks, at: now)
        var states: [Int: TrackConfirmation] = [:]
        for track in tracks {
            guard let entry = entries[track.id] else { continue }
            if entry.verdict != nil {
                states[track.id] = .confirmed
            } else if entry.isInFlight {
                states[track.id] = .thinking
            } else if isWaiting(entry, track: track, at: now) {
                states[track.id] = .pending
            }
        }

        let confirmed = tracks.map { track -> TrackedDetection in
            guard let verdict = entries[track.id]?.verdict else { return track }
            return apply(verdict, to: track)
        }
        let records = drainRecords()

        lock.unlock()

        // Cropping and measuring happen outside the lock: they are the expensive part, and
        // the detection thread is the one paying for them.
        if let plan {
            takeSample(plan, frameImage: frameImage)
        }

        return (confirmed, ConfirmationFrame(states: states), records)
    }

    /// True when the layer intends to ask about this track but has not got to it yet, so the
    /// overlay can show it as unsettled rather than as an ordinary box.
    ///
    /// Caller holds the lock.
    private func isWaiting(_ entry: Entry, track: TrackedDetection, at now: CFAbsoluteTime) -> Bool {
        entry.verdict == nil
            && entry.attempts < maximumAttempts
            && !track.isCoasting
            && min(track.displayXywhn.width, track.displayXywhn.height) >= minimumBoxSide
    }

    /// Caller holds the lock.
    private func drainRecords() -> [FoundationVerdictRecord] {
        guard !pendingRecords.isEmpty else { return [] }
        defer { pendingRecords.removeAll(keepingCapacity: true) }
        return pendingRecords
    }
}
