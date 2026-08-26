import CoreGraphics
import Foundation


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

    var effectiveThrowFeedbackGrace: CFAbsoluteTime {
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


    var objects: [ZoneTrackedObject] = []
    /// Tracker id → object, for the common case where the id simply continues.
    var byTrackID: [Int: ZoneTrackedObject] = [:]
    /// Lid state as of the previous frame, and when each bin was last seen flipping from
    /// shut to open. The open-lid witness rule only counts *transitions*: a lid that has
    /// simply been standing open says nothing about the item now vanishing beside it.
    private var binOpenNow: Set<String> = []
    var binOpenedAt: [String: CFAbsoluteTime] = [:]
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
