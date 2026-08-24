import CoreGraphics
import Foundation

/// An item that was released into a bin — the "thrown away" event.
nonisolated struct ZoneDeposit: Identifiable, Equatable, Sendable {
    /// Stable across the blinks and class flips the object survived.
    let id: UUID
    /// Tracker id the object carried when it was last seen, for cross-referencing the raw log.
    let trackID: Int
    let classKey: String
    let className: String
    let conf: Float
    /// Last box the object was seen in, normalized image space — inside the zone for an
    /// ordinary deposit, just short of it for a trajectory one.
    let boxXywhn: CGRect
    let zoneID: UUID
    let zoneName: String
    let zoneBinID: String
    let dwellFrames: Int
    /// How many tracker ids this object went through — anything above 1 means the model
    /// lost it and it was stitched back together.
    let trackSegments: Int
    /// Distinct classes the model reported over the object's life. Above 1 means the
    /// category below is a vote, not a single confident answer.
    let classesSeen: Int
    /// True when the object was never seen strictly inside the zone: it vanished on its way
    /// in and was credited by where it was heading. `dwellFrames` is 0 for these.
    let viaTrajectory: Bool
    /// True when the target bin was open during the settling window. Credited deposits
    /// always have this true, because a closed lid is not counted.
    let binWasOpen: Bool

    /// True when the detected category matches the bin the item went into.
    var isCorrect: Bool { BinGuide.info(for: classKey).id == zoneBinID }
}

/// Early HUD cue: a throw preview or an item held in the wrong zone. Not a scored deposit.
nonisolated struct ThrowFeedbackCue: Equatable, Sendable {
    let objectID: UUID
    let zoneBinID: String
    let isCorrect: Bool
    /// In-zone incorrect stays up until cancel; throw previews use the 1.8s auto-dismiss.
    let persistWhilePresent: Bool
}

/// What one frame of zone evaluation produced.
nonisolated struct ZoneFrameResult: Equatable, Sendable {
    /// Items confirmed released this frame. Confirmation lags the disappearance by the
    /// reacquisition window, because that is the point.
    var deposits: [ZoneDeposit] = []
    /// Zones with an item inside them right now — drives the dashed live outline.
    var occupiedZoneIDs: Set<UUID> = []
    /// Subset of `occupiedZoneIDs` whose item has met the dwell requirement and would be
    /// counted if it stayed gone.
    var armedZoneIDs: Set<UUID> = []
    /// Zones holding an object that has vanished and is inside its reacquisition window —
    /// about to be counted unless the model finds it again.
    var settlingZoneIDs: Set<UUID> = []
    /// First-time throw / wrong-zone feedback this frame.
    var throwFeedbackCues: [ThrowFeedbackCue] = []
    /// Objects whose preview should come down (left the wrong zone, or came back).
    var cancelledThrowFeedbackIDs: Set<UUID> = []
}

/// Decides when an item counts as thrown away.
///
/// The unit of reasoning is the **object**, not the tracker id. `DetectionTracker` starts a
/// fresh id whenever the model blinks for more than `maxMisses` frames. It does associate
/// across a class change when the boxes overlap enough; the overlay label is a short
/// confidence vote, not a new id. When overlap is too low, a relabel still arrives as a
/// new id (sometimes beside a frozen coast of the old one). Treating each id as its own
/// item is what makes a momentary dropout look like a throw, and what makes the throw
/// that follows look like waste that materialised inside the bin.
///
/// So an object here spans ids. A new track that appears where a recently lost one was is
/// assumed to be the same thing, whatever the model now calls it, and inherits its history.
/// Overlay labels are ignored for scoring: this layer votes on the raw YOLO class.
///
/// Four conditions have to hold for a deposit, each ruling out a different false positive:
///
/// - the object **arrived from outside the bin**. Something the model only ever saw inside an
///   open bin was never thrown in on camera — it is bin contents. An object already being
///   tracked keeps this credit through a blink, so reappearing inside the zone is fine; and an
///   object first seen inside a *closed* bin keeps it too, because a shut lid cannot have
///   produced it;
/// - it either stayed inside one zone for `requiredDwellFrames` of frames the model actually
///   saw — so a hand passing over does not count — or it vanished within `trajectoryReach` of
///   a zone while still moving into it;
/// - it stayed gone for `reacquireGrace` after vanishing. A dropout that comes back is the
///   same object continuing, not a throw;
/// - and the target bin was **open** while it was gone. Nothing goes into a closed bin.
nonisolated final class ZoneDepositDetector {
    /// Detected frames an object must spend inside one zone before it can be credited.
    var requiredDwellFrames: Int = 3
    /// How long a vanished object is given to come back before it is judged. Also the delay
    /// between a real throw and it appearing in the log.
    var reacquireGrace: CFAbsoluteTime = 1.4
    /// How long after a vanish (or a hold in the wrong zone) before the HUD reacts.
    /// Scoring still waits for `reacquireGrace`.
    var throwFeedbackGrace: CFAbsoluteTime = 0.4

    private var effectiveThrowFeedbackGrace: CFAbsoluteTime {
        min(throwFeedbackGrace, reacquireGrace)
    }
    /// How far a reappearing box may sit from where the object was lost, in normalized
    /// image widths, at the instant it vanishes.
    var reacquireRadius: CGFloat = 0.10
    /// Extra search radius per second missing. Sized so a carry from the mid-frame gap
    /// into a bin during a short blink still stitches; a 0.4s dropout can cover ~0.3.
    var reacquireDriftPerSecond: CGFloat = 0.55
    /// Ceiling so a long dropout cannot claim a box on the far side of the frame.
    var reacquireMaxRadius: CGFloat = 0.35

    /// Lid signal for the two rules that depend on it. Defaults to `AlwaysOpenBins`.
    /// The live camera replaces this each frame with `FrameBinOpenState` from AprilTag.
    var binOpenState: BinOpenStateProviding = AlwaysOpenBins()

    /// How far the last motion is projected forward when an object vanishes outside every
    /// zone, in normalized image widths. Roughly a hand's width: the model routinely loses an
    /// item in the last few centimetres — behind the hand releasing it, or under the lid — and
    /// the calibrated quad is the bin mouth, not the whole catchment around it.
    var trajectoryReach: CGFloat = 0.12
    /// Minimum smoothed speed, in normalized widths per second, for a direction of travel to
    /// mean anything. Below this the object was resting and the box was merely jittering.
    var trajectoryMinSpeed: CGFloat = 0.15
    /// Detected frames an object needs before its trajectory alone can credit a bin, so a
    /// two-frame flicker beside an open bin is not a throw.
    var trajectoryMinFrames: Int = 3
    /// Weight of the newest sample in the smoothed velocity.
    var velocitySmoothing: CGFloat = 0.4

    private struct Sighting {
        var center: CGPoint
        var box: CGRect
        var classKey: String
        var className: String
        var conf: Float
        /// Set once the on-device model has named this item.
        var confirmedBinID: String?
    }

    /// The bin an object would be credited to if it never comes back.
    private struct Target {
        let zoneID: UUID
        let zoneName: String
        let binID: String
        let viaTrajectory: Bool
    }

    private final class TrackedObject {
        let id = UUID()
        var trackID: Int
        var trackSegments = 1
        /// Cumulative confidence per class, so a flicker to the wrong label does not
        /// outvote a steady reading.
        var classWeights: [String: (className: String, weight: Float, conf: Float)] = [:]
        /// A Foundation-model confirmation, once one has been attached to this object.
        ///
        /// Not a vote. The tally below sums confidence over every frame, so an item seen for
        /// a second before the model answers has already banked far more weight for the
        /// detector's guess than the confirmation could ever outvote — and the model is
        /// asked precisely because that guess is the thing in doubt. A confirmation
        /// therefore replaces the tally outright.
        var confirmed: (key: String, name: String, conf: Float)?
        /// Evidence the object is not simply waste already lying in a bin: it was seen
        /// outside every zone at some point, or it was first seen inside a *closed* one.
        var arrivedFromOutside = false
        var zoneID: UUID?
        var zoneName = ""
        var zoneBinID = ""
        var dwell = 0
        /// When the object entered its current zone. Nil when it is outside every zone.
        var zoneEnteredAt: CFAbsoluteTime?
        /// A vanish-preview cue has already been sent for this disappearance.
        var didEmitThrowFeedback = false
        /// An in-zone "Not here!" cue is currently live.
        var didEmitInZoneIncorrect = false
        /// The wrong bin the in-zone cue was for — used to ignore short blinks and edge jitter.
        var lastWrongZoneBinID: String?
        /// When the object first left `lastWrongZoneBinID`. Nil while it is still there
        /// (including a vanish whose pending target is that same bin).
        var leftWrongZoneAt: CFAbsoluteTime?
        /// Frames the model actually saw this object, across every id it wore.
        var detectedFrames = 0
        var last: Sighting
        var lastSeenAt: CFAbsoluteTime
        /// Smoothed motion in normalized widths per second — the direction a vanish is
        /// judged against.
        var velocity: CGPoint = .zero
        /// Last sighting that was inside a zone, which is what an ordinary deposit reports.
        var lastInZone: Sighting?
        var missingSince: CFAbsoluteTime?
        /// Resolved once, on the frame the object vanishes. Nil means it can never be
        /// credited, so it is neither settling now nor a deposit later.
        var pendingTarget: Target?
        /// Whether the target bin has been seen open at any point since the object vanished.
        var sawBinOpen = false

        init(trackID: Int, sighting: Sighting, at time: CFAbsoluteTime) {
            self.trackID = trackID
            self.last = sighting
            self.lastSeenAt = time
        }

        func note(_ sighting: Sighting, at time: CFAbsoluteTime, smoothing: CGFloat) {
            if detectedFrames > 0 {
                let dt = CGFloat(max(time - lastSeenAt, 1e-3))
                let instant = CGPoint(
                    x: (sighting.center.x - last.center.x) / dt,
                    y: (sighting.center.y - last.center.y) / dt
                )
                velocity = CGPoint(
                    x: smoothing * instant.x + (1 - smoothing) * velocity.x,
                    y: smoothing * instant.y + (1 - smoothing) * velocity.y
                )
            }
            detectedFrames += 1
            lastSeenAt = time
            last = sighting
            if sighting.confirmedBinID != nil {
                confirmed = (sighting.classKey, sighting.className, sighting.conf)
            }
            let existing = classWeights[sighting.classKey]
            classWeights[sighting.classKey] = (
                className: sighting.className,
                weight: (existing?.weight ?? 0) + sighting.conf,
                conf: sighting.conf
            )
        }

        /// What the item goes into the log as: the model's confirmation if there is one,
        /// otherwise the class with the most confidence behind it across the object's life.
        var verdictClass: (key: String, name: String, conf: Float) {
            if let confirmed { return confirmed }
            let best = classWeights.max { a, b in
                a.value.weight == b.value.weight ? a.key < b.key : a.value.weight < b.value.weight
            }
            guard let best else { return (last.classKey, last.className, last.conf) }
            return (best.key, best.value.className, best.value.conf)
        }
    }

    private var objects: [TrackedObject] = []
    /// Tracker id → object, for the common case where the id simply continues.
    private var byTrackID: [Int: TrackedObject] = [:]

    func reset() {
        objects.removeAll(keepingCapacity: true)
        byTrackID.removeAll(keepingCapacity: true)
    }

    func update(
        tracks: [TrackedDetection],
        zones: [DropZone],
        timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> ZoneFrameResult {
        guard !zones.isEmpty else {
            reset()
            return ZoneFrameResult()
        }

        var seenThisFrame = Set<ObjectIdentifier>()
        var occupied = Set<UUID>()
        var throwFeedbackCues: [ThrowFeedbackCue] = []
        var cancelledThrowFeedbackIDs = Set<UUID>()

        // Coasting boxes are dropped outright. The tracker keeps emitting a frozen box for
        // `maxMisses` frames after the model stops finding something. When association
        // fails (low IoU relabel), it coasts the old track *while* the new one is already
        // live. Both are in this array at once. Treating the frozen box as a sighting
        // keeps the old object out of the missing state, so the new track cannot adopt it —
        // it becomes a fresh object born inside the zone, ineligible forever, while the old
        // one later dies still armed and fires a throw that never happened.
        //
        // A frozen box is not evidence: the model saw nothing. Ignoring it makes the object
        // go missing the moment the model actually loses it, which is when the reacquisition
        // window should start anyway.
        let live = tracks.filter { !$0.isCoasting }
        // Continuing ids are claimed before any adoption is attempted. Track order within a
        // frame is arbitrary, so without this a new track could adopt an object whose own
        // live track simply had not been processed yet — merging two things that are both
        // on screen. After this pass, anything still unclaimed is genuinely unaccounted for.
        let (continuing, fresh) = live.partitioned(by: { byTrackID[$0.id] != nil })

        for track in continuing + fresh {
            // `vote` is this frame's raw detection normally, and the locked Foundation-model
            // verdict once there is one — so a confirmed category reaches the deposit log
            // rather than stopping at the overlay.
            let vote = track.vote
            let sighting = Sighting(
                center: CGPoint(x: track.displayXywhn.midX, y: track.displayXywhn.midY),
                box: track.displayXywhn,
                classKey: vote.classKey,
                className: vote.className,
                conf: vote.conf,
                confirmedBinID: track.confirmedBinID
            )
            let object = resolveObject(
                for: track,
                sighting: sighting,
                now: timestamp,
                claimed: seenThisFrame
            )
            seenThisFrame.insert(ObjectIdentifier(object))
            let isFirstSighting = object.detectedFrames == 0
            let wasMissing = object.missingSince != nil
            // Back on camera: whatever it was about to be judged as no longer applies.
            object.missingSince = nil
            object.pendingTarget = nil
            object.sawBinOpen = false
            object.note(sighting, at: timestamp, smoothing: velocitySmoothing)

            if wasMissing, object.didEmitThrowFeedback {
                cancelledThrowFeedbackIDs.insert(object.id)
                object.didEmitThrowFeedback = false
            }

            guard let zone = zones.first(where: { $0.contains(sighting.center) }) else {
                // Outside every zone: this is what earns the right to be counted later.
                object.arrivedFromOutside = true
                object.zoneID = nil
                object.dwell = 0
                object.lastInZone = nil
                noteWrongZoneOccupancy(object, currentBinID: nil, at: timestamp)
                if let id = expireInZoneIncorrectIfNeeded(object, at: timestamp) {
                    cancelledThrowFeedbackIDs.insert(id)
                }
                continue
            }

            occupied.insert(zone.id)
            object.lastInZone = sighting

            // Materialising inside a zone only disqualifies an object while the bin is open,
            // because only an open bin can be where it came from. Appearing on a shut lid
            // means it arrived from outside by definition, and it stays throwable.
            if isFirstSighting, !binOpenState.isOpen(binID: zone.binID) {
                object.arrivedFromOutside = true
            }

            if object.zoneID != zone.id {
                object.zoneID = zone.id
                object.zoneName = zone.name
                object.zoneBinID = zone.binID
                object.dwell = 0
                object.zoneEnteredAt = timestamp
            } else if object.zoneEnteredAt == nil {
                object.zoneEnteredAt = timestamp
            }
            // Every frame that reaches here is one the model actually saw, so dwell only
            // ever counts real evidence.
            object.dwell += 1

            noteWrongZoneOccupancy(object, currentBinID: zone.binID, at: timestamp)
            if let id = expireInZoneIncorrectIfNeeded(object, at: timestamp) {
                cancelledThrowFeedbackIDs.insert(id)
            }
            if let cue = inZoneIncorrectCue(for: object, at: timestamp) {
                throwFeedbackCues.append(cue)
            }
        }

        // Anything not seen this frame starts, or continues, its reacquisition window.
        for object in objects where !seenThisFrame.contains(ObjectIdentifier(object)) {
            if object.missingSince == nil {
                object.missingSince = timestamp
                // The last sighting is all the evidence there will ever be, so the bin this
                // object would be credited to is settled here, once.
                object.pendingTarget = target(for: object, zones: zones)
            }
            // An open reading anywhere in the settling window counts. The lid signal is noisy
            // in its own right and can lag the throw by a few frames; demanding that two noisy
            // signals coincide on one exact frame would drop real deposits.
            if let target = object.pendingTarget, binOpenState.isOpen(binID: target.binID) {
                object.sawBinOpen = true
            }
            noteWrongZoneOccupancy(object, currentBinID: object.pendingTarget?.binID, at: timestamp)
            if let id = expireInZoneIncorrectIfNeeded(object, at: timestamp) {
                cancelledThrowFeedbackIDs.insert(id)
            }
            if let cue = throwPreviewCue(for: object, at: timestamp) {
                throwFeedbackCues.append(cue)
            }
        }

        let settled = objects.filter { object in
            guard let missingSince = object.missingSince else { return false }
            return timestamp - missingSince >= reacquireGrace
        }
        var deposits: [ZoneDeposit] = []
        for object in settled {
            deposits.append(contentsOf: deposit(from: object))
        }
        if !settled.isEmpty {
            let dead = Set(settled.map(ObjectIdentifier.init))
            objects.removeAll { dead.contains(ObjectIdentifier($0)) }
            byTrackID = byTrackID.filter { !dead.contains(ObjectIdentifier($0.value)) }
        }

        var armedZoneIDs = Set<UUID>()
        var settlingZoneIDs = Set<UUID>()
        for object in objects {
            if let target = object.pendingTarget {
                settlingZoneIDs.insert(target.zoneID)
                continue
            }
            guard object.missingSince == nil,
                  object.arrivedFromOutside,
                  let zoneID = object.zoneID,
                  object.dwell >= requiredDwellFrames
            else { continue }
            armedZoneIDs.insert(zoneID)
        }

        return ZoneFrameResult(
            deposits: deposits.sorted { $0.trackID < $1.trackID },
            occupiedZoneIDs: occupied,
            armedZoneIDs: armedZoneIDs,
            settlingZoneIDs: settlingZoneIDs,
            throwFeedbackCues: throwFeedbackCues,
            cancelledThrowFeedbackIDs: cancelledThrowFeedbackIDs
        )
    }

    private func throwPreviewCue(for object: TrackedObject, at timestamp: CFAbsoluteTime) -> ThrowFeedbackCue? {
        guard !object.didEmitThrowFeedback,
              let missingSince = object.missingSince,
              let target = object.pendingTarget,
              timestamp - missingSince >= effectiveThrowFeedbackGrace
        else { return nil }
        // Already holding "Not here!" on this bin — do not fire a second cue.
        if object.didEmitInZoneIncorrect, object.lastWrongZoneBinID == target.binID {
            return nil
        }
        object.didEmitThrowFeedback = true
        let isCorrect = BinGuide.info(for: object.verdictClass.key).id == target.binID
        return ThrowFeedbackCue(
            objectID: object.id,
            zoneBinID: target.binID,
            isCorrect: isCorrect,
            persistWhilePresent: false
        )
    }

    private func inZoneIncorrectCue(for object: TrackedObject, at timestamp: CFAbsoluteTime) -> ThrowFeedbackCue? {
        guard object.arrivedFromOutside,
              !object.didEmitInZoneIncorrect,
              object.missingSince == nil,
              !object.zoneBinID.isEmpty,
              let entered = object.zoneEnteredAt,
              timestamp - entered >= throwFeedbackGrace
        else { return nil }
        let category = BinGuide.info(for: object.verdictClass.key).id
        guard category != BinGuide.unknown.id, category != object.zoneBinID else { return nil }
        object.didEmitInZoneIncorrect = true
        object.lastWrongZoneBinID = object.zoneBinID
        object.leftWrongZoneAt = nil
        return ThrowFeedbackCue(
            objectID: object.id,
            zoneBinID: object.zoneBinID,
            isCorrect: false,
            persistWhilePresent: true
        )
    }

    /// Treat a vanish into the same wrong bin as still "there" so a blink does not cancel.
    private func noteWrongZoneOccupancy(
        _ object: TrackedObject,
        currentBinID: String?,
        at timestamp: CFAbsoluteTime
    ) {
        guard object.didEmitInZoneIncorrect, let last = object.lastWrongZoneBinID else { return }
        if currentBinID == last {
            object.leftWrongZoneAt = nil
        } else if object.leftWrongZoneAt == nil {
            object.leftWrongZoneAt = timestamp
        }
    }

    private func expireInZoneIncorrectIfNeeded(
        _ object: TrackedObject,
        at timestamp: CFAbsoluteTime
    ) -> UUID? {
        guard object.didEmitInZoneIncorrect,
              let left = object.leftWrongZoneAt,
              timestamp - left >= throwFeedbackGrace
        else { return nil }
        object.didEmitInZoneIncorrect = false
        object.lastWrongZoneBinID = nil
        object.leftWrongZoneAt = nil
        return object.id
    }

    /// Resolves a live track to the object it belongs to, stitching across a dropout when
    /// the geometry says it is the same thing.
    private func resolveObject(
        for track: TrackedDetection,
        sighting: Sighting,
        now: CFAbsoluteTime,
        claimed: Set<ObjectIdentifier>
    ) -> TrackedObject {
        if let known = byTrackID[track.id] {
            return known
        }

        var best: TrackedObject?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for candidate in objects {
            // Two objects visible at once are two objects, however similar they look — so
            // anything already claimed this frame is off limits. `missingSince` is nil for
            // an object the model lost only moments ago, on this very frame, which is
            // exactly the case a relabel produces when the tracker confirms the new id
            // immediately: elapsed is zero, and it is still the same thing.
            guard !claimed.contains(ObjectIdentifier(candidate)) else { continue }
            let elapsed = candidate.missingSince.map { now - $0 } ?? 0
            guard elapsed <= reacquireGrace else { continue }
            // Deliberately class-blind. The model relabelling a cup mid-carry is one of the
            // things this layer exists to absorb.
            let limit = min(
                reacquireMaxRadius,
                reacquireRadius + reacquireDriftPerSecond * CGFloat(max(0, elapsed))
            )
            let dx = candidate.last.center.x - sighting.center.x
            let dy = candidate.last.center.y - sighting.center.y
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance <= limit, distance < bestDistance else { continue }
            bestDistance = distance
            best = candidate
        }

        if let best {
            byTrackID[best.trackID] = nil
            best.trackID = track.id
            best.trackSegments += 1
            byTrackID[track.id] = best
            return best
        }

        let created = TrackedObject(trackID: track.id, sighting: sighting, at: now)
        objects.append(created)
        byTrackID[track.id] = created
        return created
    }

    /// The bin a vanished object would be credited to, or nil if it can never be credited.
    private func target(for object: TrackedObject, zones: [DropZone]) -> Target? {
        // Waste the model only ever saw inside an open bin stays bin contents, whatever it
        // does next.
        guard object.arrivedFromOutside else { return nil }

        if let zoneID = object.zoneID {
            // Lost inside a zone: the dwell rule decides, exactly as before.
            guard object.dwell >= requiredDwellFrames else { return nil }
            return Target(
                zoneID: zoneID,
                zoneName: object.zoneName,
                binID: object.zoneBinID,
                viaTrajectory: false
            )
        }
        return trajectoryTarget(for: object, zones: zones)
    }

    /// Where an object that vanished *outside* every zone was headed.
    ///
    /// The last box is marched forward along the smoothed direction of travel, and the first
    /// zone it reaches within `trajectoryReach` wins. This only ever runs for an object lost
    /// outside every zone — one lost inside a zone goes through the dwell rule instead — so
    /// the projection can never trivially credit a zone the item is already sitting in.
    private func trajectoryTarget(for object: TrackedObject, zones: [DropZone]) -> Target? {
        guard object.detectedFrames >= trajectoryMinFrames else { return nil }
        let velocity = object.velocity
        let speed = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
        guard speed >= trajectoryMinSpeed else { return nil }
        let dx = velocity.x / speed
        let dy = velocity.y / speed

        // Only bins the object was actually closing on. Without this a box already
        // overlapping a zone edge would be credited even as it is carried away from it.
        let center = object.last.center
        let approaching = zones.filter { zone in
            let toZone = CGPoint(x: zone.centroid.x - center.x, y: zone.centroid.y - center.y)
            return toZone.x * dx + toZone.y * dy > 0
        }
        guard !approaching.isEmpty else { return nil }

        let step: CGFloat = 0.01
        var travelled: CGFloat = 0
        while travelled <= trajectoryReach {
            let probe = object.last.box.offsetBy(dx: dx * travelled, dy: dy * travelled)
            // The whole box, not just its center: an item whose leading edge is already over
            // the bin mouth has arrived, even though its center has not.
            let samples = [
                CGPoint(x: probe.midX, y: probe.midY),
                CGPoint(x: probe.minX, y: probe.minY),
                CGPoint(x: probe.maxX, y: probe.minY),
                CGPoint(x: probe.maxX, y: probe.maxY),
                CGPoint(x: probe.minX, y: probe.maxY),
            ]
            let hit = approaching.first { zone in samples.contains(where: zone.contains) }
            if let hit {
                return Target(
                    zoneID: hit.id,
                    zoneName: hit.name,
                    binID: hit.binID,
                    viaTrajectory: true
                )
            }
            travelled += step
        }
        return nil
    }

    private func deposit(from object: TrackedObject) -> [ZoneDeposit] {
        // Nothing goes into a closed bin.
        guard let target = object.pendingTarget, object.sawBinOpen else { return [] }

        let verdict = object.verdictClass
        let box = target.viaTrajectory
            ? object.last.box
            : (object.lastInZone?.box ?? object.last.box)
        return [
            ZoneDeposit(
                id: object.id,
                trackID: object.trackID,
                classKey: verdict.key,
                className: verdict.name,
                conf: verdict.conf,
                boxXywhn: box,
                zoneID: target.zoneID,
                zoneName: target.zoneName,
                zoneBinID: target.binID,
                dwellFrames: target.viaTrajectory ? 0 : object.dwell,
                trackSegments: object.trackSegments,
                classesSeen: object.classWeights.count,
                viaTrajectory: target.viaTrajectory,
                binWasOpen: object.sawBinOpen
            ),
        ]
    }
}

private extension Array {
    /// Splits into the elements matching the predicate and the rest, preserving order.
    func partitioned(by matches: (Element) -> Bool) -> (matching: [Element], rest: [Element]) {
        var a: [Element] = []
        var b: [Element] = []
        for element in self {
            if matches(element) { a.append(element) } else { b.append(element) }
        }
        return (a, b)
    }
}
