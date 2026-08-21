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

    private let service: CategoryConfirming
    private let lock = NSLock()

    private final class Entry {
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
    private struct Orphan {
        let verdict: ConfirmedCategory
        let center: CGPoint
        let lostAt: CFAbsoluteTime
    }

    private var entries: [Int: Entry] = [:]
    private var orphans: [Orphan] = []
    /// Finished readings waiting to be handed out. They ride the caller's existing hop to
    /// the main thread rather than opening a second path of their own.
    private var pendingRecords: [FoundationVerdictRecord] = []
    /// The single outstanding request, if any. Held as the track it belongs to rather than a
    /// bare flag so a late answer cannot free a slot that has since been handed to somebody
    /// else.
    private var inFlight: (trackID: Int, startedAt: CFAbsoluteTime)?

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

        let request = nextRequest(tracks: tracks, at: now)
        var states: [Int: TrackConfirmation] = [:]
        for track in tracks {
            guard let entry = entries[track.id] else { continue }
            if entry.verdict != nil {
                states[track.id] = .confirmed
            } else if entry.isInFlight {
                states[track.id] = .thinking
            }
        }

        let confirmed = tracks.map { track -> TrackedDetection in
            guard let verdict = entries[track.id]?.verdict else { return track }
            return apply(verdict, to: track)
        }
        let records = drainRecords()

        lock.unlock()

        if let request {
            send(request, frameImage: frameImage)
        }

        return (confirmed, ConfirmationFrame(states: states), records)
    }

    /// Caller holds the lock.
    private func drainRecords() -> [FoundationVerdictRecord] {
        guard !pendingRecords.isEmpty else { return [] }
        defer { pendingRecords.removeAll(keepingCapacity: true) }
        return pendingRecords
    }

    // MARK: - Bookkeeping

    /// Parks the verdicts of tracks that are no longer in the frame, so a dropout does not
    /// silently unlock a category.
    private func retireVanishedTracks(stillPresent: Set<Int>, at now: CFAbsoluteTime) {
        let gone = entries.filter { !stillPresent.contains($0.key) }
        guard !gone.isEmpty else { return }
        for (id, entry) in gone {
            if let verdict = entry.verdict {
                orphans.append(Orphan(verdict: verdict, center: entry.center, lostAt: now))
            }
            entries[id] = nil
        }
    }

    /// Starts an entry for a new track, inheriting a nearby parked verdict when there is one.
    ///
    /// Identity here is decided on position alone — deliberately class-blind, since the model
    /// relabelling an item mid-carry is one of the things this layer exists to absorb. The
    /// window each parked verdict is searched in widens with how long it has been missing.
    private func adopt(trackID: Int, center: CGPoint, at now: CFAbsoluteTime) -> Entry {
        let entry = Entry(center: center)
        var bestIndex: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, orphan) in orphans.enumerated() {
            let elapsed = max(0, now - orphan.lostAt)
            let limit = min(
                readoptMaxRadius,
                readoptRadius + readoptDriftPerSecond * CGFloat(elapsed)
            )
            let dx = orphan.center.x - center.x
            let dy = orphan.center.y - center.y
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance <= limit, distance < bestDistance else { continue }
            bestDistance = distance
            bestIndex = index
        }
        if let bestIndex {
            entry.verdict = orphans[bestIndex].verdict
            // A re-adopted item is already known, so it is not asked about again.
            entry.frames = minimumTrackFrames
            orphans.remove(at: bestIndex)
        }
        entries[trackID] = entry
        return entry
    }

    private func apply(_ verdict: ConfirmedCategory, to track: TrackedDetection) -> TrackedDetection {
        let bin = BinGuide.bin(id: verdict.binID)
        return TrackedDetection(
            id: track.id,
            classKey: bin.id,
            className: bin.title,
            // The model's own confidence, so the label and the number beside it come from
            // the same source. YOLO's score belonged to the class it was outvoted on.
            conf: Float(verdict.confidence),
            displayXywhn: track.displayXywhn,
            misses: track.misses,
            // The detector's own opinion is left exactly as it was. It is what the session
            // log records under `rawClassKey`, and throwing it away would make the two
            // approaches impossible to compare afterwards. `confirmedBinID` is what makes
            // the lock stick: everything that counts reads `TrackedDetection.vote`, which
            // prefers it.
            rawClassKey: track.rawClassKey,
            rawConf: track.rawConf,
            confirmedBinID: bin.id
        )
    }

    // MARK: - Queueing

    private struct Request {
        let trackID: Int
        let box: CGRect
        /// What the detector called it when the crop was taken, kept for the debug log.
        let detectorClassKey: String
    }

    /// The one track to ask about now: the biggest box that is eligible, because that is the
    /// item being presented rather than something already in a bin.
    private func nextRequest(tracks: [TrackedDetection], at now: CFAbsoluteTime) -> Request? {
        if let inFlight, now - inFlight.startedAt > requestTimeout {
            // Took the slot back. The abandoned answer, if it ever lands, is ignored.
            entries[inFlight.trackID]?.isInFlight = false
            self.inFlight = nil
        }
        guard inFlight == nil else { return nil }

        var best: TrackedDetection?
        var bestArea: CGFloat = 0
        for track in tracks {
            guard !track.isCoasting,
                  let entry = entries[track.id],
                  entry.verdict == nil,
                  !entry.isInFlight,
                  entry.attempts < maximumAttempts,
                  now >= entry.nextAttemptAt,
                  entry.frames >= minimumTrackFrames
            else { continue }
            let box = track.displayXywhn
            guard min(box.width, box.height) >= minimumBoxSide else { continue }
            let area = box.width * box.height
            guard area > bestArea else { continue }
            bestArea = area
            best = track
        }

        guard let best, let entry = entries[best.id] else { return nil }
        entry.isInFlight = true
        entry.attempts += 1
        inFlight = (trackID: best.id, startedAt: now)
        return Request(
            trackID: best.id,
            box: best.displayXywhn,
            detectorClassKey: best.observedClassKey
        )
    }

    private func send(_ request: Request, frameImage: () -> CGImage?) {
        guard let frame = frameImage(),
              let crop = ItemCropper.crop(
                  frame,
                  to: request.box,
                  padding: cropPadding,
                  maximumSide: cropMaximumSide
              )
        else {
            // No usable pixels this frame. Release the slot and let the next frame retry —
            // this is not a refusal by the model, so it does not burn an attempt.
            lock.lock()
            entries[request.trackID]?.isInFlight = false
            entries[request.trackID]?.attempts -= 1
            if inFlight?.trackID == request.trackID { inFlight = nil }
            lock.unlock()
            return
        }

        // Taken from the crop rather than the frame, so what the log shows is exactly what
        // the model was shown — including a badly placed box, which is what most surprising
        // answers turn out to be.
        let thumbnail = ItemCropper.downscaled(crop, maximumSide: thumbnailMaximumSide)
        let service = self.service
        let startedAt = clock()
        dispatch { [weak self] in
            do {
                let reading = try await service.read(image: crop)
                self?.finish(
                    request: request,
                    reading: reading,
                    failure: nil,
                    startedAt: startedAt,
                    thumbnail: thumbnail
                )
            } catch {
                self?.finish(
                    request: request,
                    reading: nil,
                    failure: String(describing: error),
                    startedAt: startedAt,
                    thumbnail: thumbnail
                )
            }
        }
    }

    private func finish(
        request: Request,
        reading: CategoryReading?,
        failure: String?,
        startedAt: CFAbsoluteTime,
        thumbnail: CGImage?
    ) {
        lock.lock()
        defer { lock.unlock() }

        let now = clock()
        // Only the current holder may free the slot. An answer that arrives after its
        // request timed out finds the slot already reassigned and leaves it alone.
        if inFlight?.trackID == request.trackID { inFlight = nil }

        let accepted = accept(reading)
        pendingRecords.append(
            record(
                for: request,
                reading: reading,
                accepted: accepted,
                failure: failure,
                latency: max(0, now - startedAt),
                thumbnail: thumbnail
            )
        )

        guard let entry = entries[request.trackID] else { return }
        entry.isInFlight = false
        if let accepted {
            entry.verdict = accepted
        } else {
            entry.nextAttemptAt = now + retryDelay
        }
    }

    /// The one place that decides whether an answer is good enough to act on.
    private func accept(_ reading: CategoryReading?) -> ConfirmedCategory? {
        guard let reading,
              let binID = reading.binID,
              reading.confidence >= minimumConfidence
        else { return nil }
        return ConfirmedCategory(
            binID: binID,
            confidence: reading.confidence,
            label: reading.label
        )
    }

    private func record(
        for request: Request,
        reading: CategoryReading?,
        accepted: ConfirmedCategory?,
        failure: String?,
        latency: TimeInterval,
        thumbnail: CGImage?
    ) -> FoundationVerdictRecord {
        let outcome: FoundationVerdictRecord.Outcome
        if let accepted {
            outcome = .locked(binID: accepted.binID)
        } else if let failure {
            outcome = .failed(failure)
        } else if let reading, reading.binID == nil {
            outcome = .declined(reason: "model answered unclear")
        } else if let reading {
            outcome = .declined(
                reason: String(format: "below %.2f confidence", minimumConfidence)
            )
        } else {
            outcome = .failed("no answer")
        }

        return FoundationVerdictRecord(
            trackID: request.trackID,
            label: reading?.label ?? "",
            confidence: reading?.confidence ?? 0,
            detectorClassKey: request.detectorClassKey,
            latency: latency,
            outcome: outcome,
            thumbnail: thumbnail
        )
    }
}
