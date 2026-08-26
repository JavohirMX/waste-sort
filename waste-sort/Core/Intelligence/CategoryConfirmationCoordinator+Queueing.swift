import CoreGraphics
import Foundation

// MARK: - Sample queueing and Foundation-model requests

extension CategoryConfirmationCoordinator {

    struct Request {
        let trackID: Int
        let box: CGRect
        /// What the detector called it when the crop was taken, kept for the debug log.
        let detectorClassKey: String
    }

    /// One frame's worth of work for the burst currently being measured.
    struct Sample {
        let request: Request
        /// True on the last frame of the burst: whatever is best after this one is sent.
        let isFinal: Bool
    }

    /// Decides what to look at this frame: continue the burst in progress, or start one on
    /// the biggest eligible box — that being the item somebody is holding up rather than
    /// something lying in a bin.
    ///
    /// Caller holds the lock.
    func planSample(tracks: [TrackedDetection], at now: CFAbsoluteTime) -> Sample? {
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
    func takeSample(_ sample: Sample, frameImage: () -> CGImage?) {
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
