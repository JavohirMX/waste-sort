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

    /// One measured look at an item.
    private struct Candidate {
        let crop: CGImage
        let sharpness: Double
        let detectorClassKey: String
    }

    /// The burst of frames currently being measured, before anything is sent.
    private struct Gathering {
        let trackID: Int
        var samples = 0
        var best: Candidate?
    }

    private var gathering: Gathering?

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

    /// One frame's worth of work for the burst currently being measured.
    private struct Sample {
        let request: Request
        /// True on the last frame of the burst: whatever is best after this one is sent.
        let isFinal: Bool
    }

    /// Decides what to look at this frame: continue the burst in progress, or start one on
    /// the biggest eligible box — that being the item somebody is holding up rather than
    /// something lying in a bin.
    ///
    /// Caller holds the lock.
    private func planSample(tracks: [TrackedDetection], at now: CFAbsoluteTime) -> Sample? {
        if let inFlight, now - inFlight.startedAt > requestTimeout {
            // Took the slot back. The abandoned answer, if it ever lands, is ignored.
            entries[inFlight.trackID]?.isInFlight = false
            self.inFlight = nil
        }
        guard inFlight == nil else { return nil }

        if let gathering {
            // The burst follows its item. If the item is gone, send the best look so far
            // rather than throwing the work away.
            guard let track = tracks.first(where: { $0.id == gathering.trackID }),
                  !track.isCoasting
            else {
                dispatchBest()
                return nil
            }
            return Sample(
                request: Request(
                    trackID: track.id,
                    box: track.displayXywhn,
                    detectorClassKey: track.observedClassKey
                ),
                isFinal: gathering.samples + 1 >= candidateFrames
            )
        }

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
        // Marked busy for the whole burst, not just the model call: the overlay should show
        // the item as being worked on from the moment we start looking at it.
        entry.isInFlight = true
        entry.attempts += 1
        gathering = Gathering(trackID: best.id)
        return Sample(
            request: Request(
                trackID: best.id,
                box: best.displayXywhn,
                detectorClassKey: best.observedClassKey
            ),
            isFinal: candidateFrames <= 1
        )
    }

    /// Crops and measures one frame, then either keeps it as the best so far or sends it.
    /// Runs without the lock held.
    private func takeSample(_ sample: Sample, frameImage: () -> CGImage?) {
        var candidate: Candidate?
        if let frame = frameImage(),
           let crop = ItemCropper.crop(
               frame,
               to: sample.request.box,
               padding: cropPadding,
               maximumSide: cropMaximumSide,
               minimumSide: minimumCropPixels
           )
        {
            candidate = Candidate(
                crop: crop,
                sharpness: ImageSharpness.score(crop),
                detectorClassKey: sample.request.detectorClassKey
            )
        }

        lock.lock()
        // A reset or a timeout may have moved on while this frame was being measured.
        guard gathering?.trackID == sample.request.trackID else {
            lock.unlock()
            return
        }
        gathering?.samples += 1
        if let candidate, candidate.sharpness > (gathering?.best?.sharpness ?? -1) {
            gathering?.best = candidate
        }
        let ready = sample.isFinal || (gathering?.samples ?? 0) >= candidateFrames
        guard ready else {
            lock.unlock()
            return
        }
        let outcome = takeGathered()
        lock.unlock()

        if let outcome {
            send(outcome.candidate, trackID: outcome.trackID)
        }
    }

    /// Ends the burst and hands back what to send, if anything. Caller holds the lock.
    private func takeGathered() -> (trackID: Int, candidate: Candidate)? {
        guard let gathering else { return nil }
        self.gathering = nil

        guard let best = gathering.best else {
            // Every frame of the burst was unusable — too small a crop, or no pixels at all.
            // That is not the model refusing, so it does not burn an attempt; but retrying
            // on the very next frame would spin, since an item too small to crop stays too
            // small, so it waits out the same pause a refusal does.
            entries[gathering.trackID]?.isInFlight = false
            entries[gathering.trackID]?.attempts -= 1
            entries[gathering.trackID]?.nextAttemptAt = clock() + retryDelay
            return nil
        }
        inFlight = (trackID: gathering.trackID, startedAt: clock())
        return (gathering.trackID, best)
    }

    /// Sends the best look at an item whose burst was cut short. Caller holds the lock.
    private func dispatchBest() {
        guard let outcome = takeGathered() else { return }
        // Deliberately dispatched while holding the lock: `dispatch` only enqueues, and the
        // work itself takes the lock later, on another thread.
        send(outcome.candidate, trackID: outcome.trackID)
    }

    private func send(_ candidate: Candidate, trackID: Int) {
        let crop = candidate.crop
        let detectorClassKey = candidate.detectorClassKey
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
                    trackID: trackID,
                    detectorClassKey: detectorClassKey,
                    reading: reading,
                    failure: nil,
                    startedAt: startedAt,
                    thumbnail: thumbnail
                )
            } catch {
                self?.finish(
                    trackID: trackID,
                    detectorClassKey: detectorClassKey,
                    reading: nil,
                    failure: String(describing: error),
                    startedAt: startedAt,
                    thumbnail: thumbnail
                )
            }
        }
    }

    private func finish(
        trackID: Int,
        detectorClassKey: String,
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
        if inFlight?.trackID == trackID { inFlight = nil }

        let accepted = accept(reading)
        let threshold = reading.flatMap { $0.binID.map(minimumConfidence(for:)) } ?? minimumConfidence
        pendingRecords.append(
            record(
                trackID: trackID,
                detectorClassKey: detectorClassKey,
                reading: reading,
                accepted: accepted,
                failure: failure,
                latency: max(0, now - startedAt),
                thumbnail: thumbnail,
                confidenceThreshold: threshold
            )
        )

        guard let entry = entries[trackID] else { return }
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
              reading.confidence >= minimumConfidence(for: binID)
        else { return nil }
        return ConfirmedCategory(
            binID: binID,
            confidence: reading.confidence,
            label: reading.label
        )
    }

    private func minimumConfidence(for binID: String) -> Double {
        if binID == BinGuide.dirtyRecyclable.id {
            return minimumDirtyRecyclableConfidence
        }
        return minimumConfidence
    }

    private func record(
        trackID: Int,
        detectorClassKey: String,
        reading: CategoryReading?,
        accepted: ConfirmedCategory?,
        failure: String?,
        latency: TimeInterval,
        thumbnail: CGImage?,
        confidenceThreshold: Double
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
                reason: String(format: "below %.2f confidence", confidenceThreshold)
            )
        } else {
            outcome = .failed("no answer")
        }

        return FoundationVerdictRecord(
            trackID: trackID,
            label: reading?.label ?? "",
            confidence: reading?.confidence ?? 0,
            detectorClassKey: detectorClassKey,
            latency: latency,
            outcome: outcome,
            thumbnail: thumbnail
        )
    }
}
