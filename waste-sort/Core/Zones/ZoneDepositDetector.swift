import CoreGraphics
import Foundation

/// An item that was released into a bin — the "thrown away" event.
nonisolated struct ZoneDeposit: Identifiable, Equatable, Sendable {
    /// Stable across the blinks and class flips the object survived.
    let id: UUID
    /// Tracker id the object carried when it was last seen, for cross-referencing the raw log.
    let trackID: Int
    /// The bin verdict the system advised. When belief was decisive this is the model's
    /// top class; when it was not, this is `BinGuide.fallbackBinID` — residual, the
    /// regulation-safe stream.
    let classKey: String
    let className: String
    /// Belief probability behind `classKey` (0…1). For fallback verdicts this is how
    /// much evidence existed at all — deliberately unimpressive.
    let conf: Float
    /// The model's own leader regardless of decisiveness, for diagnostics and CSV
    /// post-analysis of where the engine had to overrule it.
    let modelTopClassKey: String
    /// True when the verdict was resolved by fallback rather than a confident read.
    let wasUncertain: Bool
    /// Lead of the top class over the runner-up (0…1). Small values flag coin flips.
    let margin: Float
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
    /// Dirty recyclable is correct in residual or recyclable.
    var isCorrect: Bool {
        BinGuide.isAcceptedDeposit(classKey: classKey, zoneBinID: zoneBinID)
    }
}

/// Early HUD cue: a throw preview or an item held in the wrong zone. Not a scored deposit.
nonisolated struct ThrowFeedbackCue: Equatable, Sendable {
    let objectID: UUID
    let zoneBinID: String
    let isCorrect: Bool
    /// In-zone incorrect stays up until cancel; throw previews use the 1.8s auto-dismiss.
    let persistWhilePresent: Bool
}

/// Why an item that vanished never became a deposit. Surfaced on Live so a
/// kiosk that swallows throws explains itself instead of staying silent.
nonisolated enum DepositDropReason: Equatable, Sendable {
    /// Vanished with no zone under or along its path — nothing to credit.
    case outsideZones
    /// Had a target zone, but no open reading during the settling window:
    /// thrown at a bin whose lid (strip/tag) read shut.
    case binReadShut
}

/// One vanished item that did not become a deposit. Emitted on the frame it
/// was reaped; Live shows the latest one as a diagnostic chip.
nonisolated struct DepositDrop: Equatable, Sendable {
    let reason: DepositDropReason
    let trackID: Int
    /// The bin that would have been credited, when there was one.
    let targetBinID: String?
    let timestamp: CFAbsoluteTime
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
    /// Vanished items that did NOT credit this frame, with why. Usually empty;
    /// non-empty means a throw happened and was not counted.
    var drops: [DepositDrop] = []
}

/// The frozen bin verdict for an object at the moment it vanishes.
nonisolated struct DepositVerdict: Equatable, Sendable {
    let classKey: String
    let className: String
    /// Belief probability behind `classKey`.
    let conf: Float
    /// The model's own leader even when `classKey` overruled it via fallback.
    let modelTopClassKey: String
    let wasUncertain: Bool
    let margin: Float
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
///   saw — so a hand passing over does not count — or the evidence names a bin anyway: its
///   motion swept across a zone, a launch projection reaches one, or exactly one lid stood
///   open under the vanish point (drawer bins occlude the drop itself);
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
    /// zone, in normalized image widths. Baseline: roughly a hand's width — the model
    /// routinely loses an item in the last few centimetres. A fast launch stretches the
    /// projection by `trajectorySpeedReachGain` per unit of speed, capped at
    /// `trajectoryMaxReach`, because a blur-lost flight covers far more than a hand.
    /// Which decision math resolves the frozen verdict at vanish. Mirrored from
    /// settings on the inference queue, same as the tracker's copy.
    var pipeline: DecisionPipeline = .belief
    var trajectoryReach: CGFloat = 0.12
    /// Minimum smoothed speed, in normalized widths per second, for a direction of travel to
    /// mean anything. Below this the object was resting and the box was merely jittering.
    var trajectoryMinSpeed: CGFloat = 0.15
    /// Detected frames an object needs before its trajectory alone can credit a bin, so a
    /// two-frame flicker beside an open bin is not a throw.
    var trajectoryMinFrames: Int = 3
    /// Weight of the newest sample in the smoothed velocity.
    var velocitySmoothing: CGFloat = 0.4
    /// Ceiling for the speed-scaled trajectory projection, so a flung box cannot be
    /// marched across the whole frame.
    var trajectoryMaxReach: CGFloat = 0.45
    /// Seconds of travel speed added to the projection reach per unit of speed.
    var trajectorySpeedReachGain: CGFloat = 0.25
    /// How long a launch (peak instantaneous speed) stays creditable evidence of where a
    /// vanished object was headed. The smoothed velocity lags a release; the peak is the
    /// trace a throw leaves when its flight is never tracked at all.
    var peakVelocityWindow: CFAbsoluteTime = 0.35
    /// How long a swept zone crossing stays creditable: a fast item's center can jump
    /// clean over a bin mouth between two tracked frames, never inside on either.
    var crossingFreshWindow: CFAbsoluteTime = 0.35
    /// How close a vanished item must sit to the one open bin for the open lid itself to
    /// count as evidence of where it went. Drawer bins are the reason this rule exists:
    /// the drop happens behind the drawer's front edge, in frames the model never sees.
    var intentMaxDistance: CGFloat = 0.55
    /// How long before the item appeared a lid may have been pulled open and still count
    /// as evidence — the drawer pulled just before the item came into view.
    var intentOpenRecency: CFAbsoluteTime = 2.5


    private var objects: [ZoneTrackedObject] = []
    /// Tracker id → object, for the common case where the id simply continues.
    private var byTrackID: [Int: ZoneTrackedObject] = [:]
    /// Lid state as of the previous frame, and when each bin was last seen flipping from
    /// shut to open. The open-lid witness rule only counts *transitions*: a lid that has
    /// simply been standing open says nothing about the item now vanishing beside it.
    private var binOpenNow: Set<String> = []
    private var binOpenedAt: [String: CFAbsoluteTime] = [:]
    /// The first frame only learns the starting lid state; it is not a transition.
    private var binLidsBaselined = false

    /// Records shut→open flips per bin, for the open-lid witness rule. The first frame
    /// only baselines; it is not a transition.
    private func noteLidTransitions(zones: [DropZone], at timestamp: CFAbsoluteTime) {
        for zone in zones {
            let isOpen = binOpenState.isOpen(binID: zone.binID)
            if binLidsBaselined, isOpen, !binOpenNow.contains(zone.binID) {
                binOpenedAt[zone.binID] = timestamp
            }
            if isOpen {
                binOpenNow.insert(zone.binID)
            } else {
                binOpenNow.remove(zone.binID)
            }
        }
        binLidsBaselined = true
    }

    func reset() {
        objects.removeAll(keepingCapacity: true)
        byTrackID.removeAll(keepingCapacity: true)
        binOpenNow.removeAll()
        binOpenedAt.removeAll()
        binLidsBaselined = false
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

        noteLidTransitions(zones: zones, at: timestamp)

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
            let previousCenter = object.last.center
            // Back on camera: whatever it was about to be judged as no longer applies.
            object.missingSince = nil
            object.pendingTarget = nil
            object.sawBinOpen = false
            object.note(sighting, at: timestamp, smoothing: velocitySmoothing, pipeline: pipeline)

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
                recordSweptCrossing(for: object, from: previousCenter, to: sighting.center, zones: zones, at: timestamp)
                noteWrongZoneOccupancy(object, currentBinID: nil, binIsOpen: false, at: timestamp)
                if let id = expireInZoneIncorrectIfNeeded(object, at: timestamp) {
                    cancelledThrowFeedbackIDs.insert(id)
                }
                continue
            }

            occupied.insert(zone.id)
            object.lastInZone = sighting
            // The dwell rule owns every zone the object was actually tracked inside. A
            // recorded entry crossing for this zone must not outlive that judgment —
            // otherwise an item that dwelt too briefly, left, and vanished could be
            // credited by its own rejected entry.
            object.crossedZone = nil

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

            noteWrongZoneOccupancy(
                object,
                currentBinID: zone.binID,
                binIsOpen: binOpenState.isOpen(binID: zone.binID),
                at: timestamp
            )
            if let id = expireInZoneIncorrectIfNeeded(object, at: timestamp) {
                cancelledThrowFeedbackIDs.insert(id)
            }
            if let cue = inZoneIncorrectCue(for: object, at: timestamp, pipeline: pipeline) {
                throwFeedbackCues.append(cue)
            }
        }

        // Anything not seen this frame starts, or continues, its reacquisition window.
        for object in objects where !seenThisFrame.contains(ObjectIdentifier(object)) {
            if object.missingSince == nil {
                object.missingSince = timestamp
                // The last sighting is all the kinematic evidence there will ever be, so
                // the bin this object would be credited to is settled here, once.
                object.pendingTarget = target(for: object, zones: zones)
            }
            // An open lid may claim what kinematics could not: a drawer-bin drop happens
            // behind the drawer's front edge, in frames the model never sees, so the one
            // standing-open bin under the vanish point is the only witness a throw had.
            // Evidence arriving during the window, and never a downgrade — the settle-once
            // rule only ever binds kinematic targets.
            if object.pendingTarget == nil {
                object.pendingTarget = intentTarget(for: object, zones: zones)
            }
            // An open reading anywhere in the settling window counts. The lid signal is noisy
            // in its own right and can lag the throw by a few frames; demanding that two noisy
            // signals coincide on one exact frame would drop real deposits.
            let pendingOpen = object.pendingTarget.map { binOpenState.isOpen(binID: $0.binID) } ?? false
            if pendingOpen {
                object.sawBinOpen = true
            }
            noteWrongZoneOccupancy(
                object,
                currentBinID: object.pendingTarget?.binID,
                binIsOpen: pendingOpen,
                at: timestamp
            )
            if let id = expireInZoneIncorrectIfNeeded(object, at: timestamp) {
                cancelledThrowFeedbackIDs.insert(id)
            }
            if let cue = throwPreviewCue(for: object, at: timestamp, pipeline: pipeline) {
                throwFeedbackCues.append(cue)
            }
        }

        let reaped = reapAndArm(at: timestamp)

        return ZoneFrameResult(
            deposits: reaped.deposits,
            occupiedZoneIDs: occupied,
            armedZoneIDs: reaped.armedZoneIDs,
            settlingZoneIDs: reaped.settlingZoneIDs,
            throwFeedbackCues: throwFeedbackCues,
            cancelledThrowFeedbackIDs: cancelledThrowFeedbackIDs,
            drops: reaped.drops
        )
    }

    private func throwPreviewCue(
        for object: ZoneTrackedObject,
        at timestamp: CFAbsoluteTime,
        pipeline: DecisionPipeline
    ) -> ThrowFeedbackCue? {
        guard !object.didEmitThrowFeedback,
              object.sawBinOpen,
              let missingSince = object.missingSince,
              let target = object.pendingTarget,
              timestamp - missingSince >= effectiveThrowFeedbackGrace
        else { return nil }
        // Already holding "Not here!" on this bin — do not fire a second cue.
        if object.didEmitInZoneIncorrect, object.lastWrongZoneBinID == target.binID {
            return nil
        }
        object.didEmitThrowFeedback = true
        let vote = object.verdictClass(at: timestamp, pipeline: pipeline)
        let isCorrect = BinGuide.isAcceptedDeposit(classKey: vote.key, zoneBinID: target.binID)
        return ThrowFeedbackCue(
            objectID: object.id,
            zoneBinID: target.binID,
            isCorrect: isCorrect,
            persistWhilePresent: false
        )
    }

    private func inZoneIncorrectCue(
        for object: ZoneTrackedObject,
        at timestamp: CFAbsoluteTime,
        pipeline: DecisionPipeline
    ) -> ThrowFeedbackCue? {
        guard object.arrivedFromOutside,
              !object.didEmitInZoneIncorrect,
              object.missingSince == nil,
              !object.zoneBinID.isEmpty,
              binOpenState.isOpen(binID: object.zoneBinID),
              let entered = object.zoneEnteredAt,
              timestamp - entered >= throwFeedbackGrace
        else { return nil }
        let category = BinGuide.info(for: object.verdictClass(at: timestamp, pipeline: pipeline).key).id
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
    /// A shut lid is leaving: the overlay must not persist over a bin that cannot accept a throw.
    private func noteWrongZoneOccupancy(
        _ object: ZoneTrackedObject,
        currentBinID: String?,
        binIsOpen: Bool,
        at timestamp: CFAbsoluteTime
    ) {
        guard object.didEmitInZoneIncorrect, let last = object.lastWrongZoneBinID else { return }
        if currentBinID == last, binIsOpen {
            object.leftWrongZoneAt = nil
        } else if object.leftWrongZoneAt == nil {
            object.leftWrongZoneAt = timestamp
        }
    }

    private func expireInZoneIncorrectIfNeeded(
        _ object: ZoneTrackedObject,
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

    /// Everything one reaping pass produced.
    private struct ReapResult {
        var deposits: [ZoneDeposit] = []
        var drops: [DepositDrop] = []
        var armedZoneIDs: Set<UUID> = []
        var settlingZoneIDs: Set<UUID> = []
    }

    /// Scores everything whose reacquisition window ran out, drops it, and computes the
    /// per-zone armed/settling sets the HUD reacts to.
    private func reapAndArm(at timestamp: CFAbsoluteTime) -> ReapResult {
        var result = ReapResult()
        let settled = objects.filter { object in
            guard let missingSince = object.missingSince else { return false }
            return timestamp - missingSince >= reacquireGrace
        }
        for object in settled {
            let credited = deposit(from: object)
            if credited.isEmpty, let drop = dropRecord(for: object) {
                result.drops.append(drop)
            }
            result.deposits.append(contentsOf: credited)
        }
        if !settled.isEmpty {
            let dead = Set(settled.map(ObjectIdentifier.init))
            objects.removeAll { dead.contains(ObjectIdentifier($0)) }
            byTrackID = byTrackID.filter { !dead.contains(ObjectIdentifier($0.value)) }
        }

        for object in objects {
            if let target = object.pendingTarget {
                result.settlingZoneIDs.insert(target.zoneID)
                continue
            }
            guard object.missingSince == nil,
                  object.arrivedFromOutside,
                  let zoneID = object.zoneID,
                  object.dwell >= requiredDwellFrames
            else { continue }
            result.armedZoneIDs.insert(zoneID)
        }
        result.deposits.sort { $0.trackID < $1.trackID }
        result.drops.sort { $0.trackID < $1.trackID }
        return result
    }

    /// Names why a settled object earned nothing. Mirrors `deposit(from:)`'s
    /// guard so the chip on Live always states the true gate.
    private func dropRecord(for object: ZoneTrackedObject) -> DepositDrop? {
        guard let missingSince = object.missingSince else { return nil }
        if let target = object.pendingTarget {
            guard !object.sawBinOpen else { return nil }
            return DepositDrop(
                reason: .binReadShut,
                trackID: object.trackID,
                targetBinID: target.binID,
                timestamp: missingSince
            )
        }
        return DepositDrop(
            reason: .outsideZones,
            trackID: object.trackID,
            targetBinID: object.zoneBinID.isEmpty ? nil : object.zoneBinID,
            timestamp: missingSince
        )
    }

    /// Resolves a live track to the object it belongs to, stitching across a dropout when
    /// the geometry says it is the same thing.
    private func resolveObject(
        for track: TrackedDetection,
        sighting: Sighting,
        now: CFAbsoluteTime,
        claimed: Set<ObjectIdentifier>
    ) -> ZoneTrackedObject {
        if let known = byTrackID[track.id] {
            return known
        }

        var best: ZoneTrackedObject?
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

        let created = ZoneTrackedObject(trackID: track.id, sighting: sighting, at: now)
        objects.append(created)
        byTrackID[track.id] = created
        return created
    }

    /// The bin a vanished object would be credited to, or nil if it can never be credited.
    private func target(for object: ZoneTrackedObject, zones: [DropZone]) -> ZoneDepositTarget? {
        // Waste the model only ever saw inside an open bin stays bin contents, whatever it
        // does next.
        guard object.arrivedFromOutside else { return nil }

        if let zoneID = object.zoneID {
            // Lost inside a zone: the dwell rule decides, exactly as before.
            guard object.dwell >= requiredDwellFrames else { return nil }
            return ZoneDepositTarget(
                zoneID: zoneID,
                zoneName: object.zoneName,
                binID: object.zoneBinID,
                viaTrajectory: false
            )
        }
        // A swept crossing is observed motion over a bin mouth; the trajectory march is
        // inference from velocity. Direct evidence wins.
        if let crossed = object.crossedZone,
           object.lastSeenAt - object.crossedAt <= crossingFreshWindow {
            return crossed
        }
        return trajectoryTarget(for: object, zones: zones)
    }

    /// The bin to credit when kinematics name none: exactly one lid stands open and the
    /// item vanished within reach of it.
    ///
    /// Drawer bins make this the load-bearing rule in practice. The item is dropped
    /// downward behind the drawer's front edge, so the flight is occluded in the very
    /// frames where it would enter the zone — the model sees it held, then never again.
    /// You cannot put anything into a closed drawer, so a tracked item vanishing next to
    /// the one open bin is a deposit by elimination. Ambiguity is refused: two open lids
    /// name no bin at all.
    private func intentTarget(for object: ZoneTrackedObject, zones: [DropZone]) -> ZoneDepositTarget? {
        guard object.arrivedFromOutside,
              object.zoneID == nil,
              object.detectedFrames >= trajectoryMinFrames
        else { return nil }
        let open = zones.filter { binOpenState.isOpen(binID: $0.binID) }
        guard open.count == 1, let zone = open.first else { return nil }
        let dx = zone.centroid.x - object.last.center.x
        let dy = zone.centroid.y - object.last.center.y
        guard (dx * dx + dy * dy).squareRoot() <= intentMaxDistance else { return nil }
        // The lid must have been opened for this item — pulled while the item was in
        // sight, or shortly before it appeared. A lid that has been open for ages is
        // furniture, not a witness: that is how an item set down beside a bin stays
        // uncredited even when the lid happens to stand open.
        guard let openedAt = binOpenedAt[zone.binID],
              openedAt >= object.bornAt - intentOpenRecency
        else { return nil }
        return ZoneDepositTarget(zoneID: zone.id, zoneName: zone.name, binID: zone.binID, viaTrajectory: true)
    }

    /// Records the last zone an object's motion swept across between two tracked frames.
    /// Only meaningful movement counts: a segment long enough to have jumped a polygon
    /// that `contains` would have caught on one of its endpoints.
    private func recordSweptCrossing(
        for object: ZoneTrackedObject,
        from previous: CGPoint,
        to current: CGPoint,
        zones: [DropZone],
        at timestamp: CFAbsoluteTime
    ) {
        let dx = current.x - previous.x
        let dy = current.y - previous.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.02 else { return }
        let steps = Int(length / 0.02)
        var hit: ZoneDepositTarget?
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let probe = CGPoint(x: previous.x + dx * t, y: previous.y + dy * t)
            if let zone = zones.first(where: { $0.contains(probe) }) {
                // Only an entry from outside counts. A segment that starts inside the zone
                // is that zone's exit — the dwell rule already judged the time spent in it,
                // and recording the way out would resurrect what the dwell rule refused.
                if hit == nil, !zone.contains(previous) {
                    hit = ZoneDepositTarget(zoneID: zone.id, zoneName: zone.name, binID: zone.binID, viaTrajectory: true)
                }
            }
        }
        if let hit {
            object.crossedZone = hit
            object.crossedAt = timestamp
        }
    }

    /// Where an object that vanished *outside* every zone was headed.
    ///
    /// The last box is marched forward along the direction of travel, and the first zone
    /// it reaches within the (speed-scaled) reach wins. The projection rides the tracked
    /// motion; only when that motion is silence — a held item whose release was never
    /// tracked — may a fresh launch peak speak for it, and never contrary to motion the
    /// model actually saw. This only ever runs for an object lost outside every zone —
    /// one lost inside a zone goes through the dwell rule instead — so the projection can
    /// never trivially credit a zone the item is already sitting in.
    private func trajectoryTarget(for object: ZoneTrackedObject, zones: [DropZone]) -> ZoneDepositTarget? {
        guard object.detectedFrames >= trajectoryMinFrames else { return nil }
        var direction = object.velocity
        var speed = (direction.x * direction.x + direction.y * direction.y).squareRoot()
        if speed < trajectoryMinSpeed {
            let peakAge = object.lastSeenAt - object.peakAt
            if peakAge >= 0, peakAge <= peakVelocityWindow {
                let peakSpeed = (object.peakVelocity.x * object.peakVelocity.x
                    + object.peakVelocity.y * object.peakVelocity.y).squareRoot()
                if peakSpeed > speed {
                    direction = object.peakVelocity
                    speed = peakSpeed
                }
            }
        }
        guard speed >= trajectoryMinSpeed else { return nil }
        let dx = direction.x / speed
        let dy = direction.y / speed
        let reach = min(
            trajectoryMaxReach,
            trajectoryReach + speed * trajectorySpeedReachGain
        )

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
        while travelled <= reach {
            let probe = object.last.box.offsetBy(dx: dx * travelled, dy: dy * travelled)
            // The whole box, not just its center: an item whose leading edge is already over
            // the bin mouth has arrived, even though its center has not.
            let samples = [
                CGPoint(x: probe.midX, y: probe.midY),
                CGPoint(x: probe.minX, y: probe.minY),
                CGPoint(x: probe.maxX, y: probe.minY),
                CGPoint(x: probe.maxX, y: probe.maxY),
                CGPoint(x: probe.minX, y: probe.maxY)
            ]
            let hit = approaching.first { zone in samples.contains(where: zone.contains) }
            if let hit {
                return ZoneDepositTarget(
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

    private func deposit(from object: ZoneTrackedObject) -> [ZoneDeposit] {
        // Nothing goes into a closed bin.
        guard let target = object.pendingTarget, object.sawBinOpen else { return [] }

        let verdict = object.resolvedVerdict(at: object.missingSince ?? object.lastSeenAt, pipeline: pipeline)
        let box = target.viaTrajectory
            ? object.last.box
            : (object.lastInZone?.box ?? object.last.box)
        return [
            ZoneDeposit(
                id: object.id,
                trackID: object.trackID,
                classKey: verdict.classKey,
                className: verdict.className,
                conf: verdict.conf,
                modelTopClassKey: verdict.modelTopClassKey,
                wasUncertain: verdict.wasUncertain,
                margin: verdict.margin,
                boxXywhn: box,
                zoneID: target.zoneID,
                zoneName: target.zoneName,
                zoneBinID: target.binID,
                dwellFrames: target.viaTrajectory ? 0 : object.dwell,
                trackSegments: object.trackSegments,
                classesSeen: object.classesSeen,
                viaTrajectory: target.viaTrajectory,
                binWasOpen: object.sawBinOpen
            )
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
