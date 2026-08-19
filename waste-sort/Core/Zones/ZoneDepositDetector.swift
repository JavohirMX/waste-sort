import CoreGraphics
import Foundation

/// An item that was released inside a zone — the "thrown away" event.
nonisolated struct ZoneDeposit: Identifiable, Equatable, Sendable {
    /// Stable across the blinks and class flips the object survived.
    let id: UUID
    /// Tracker id the object carried when it was last seen, for cross-referencing the raw log.
    let trackID: Int
    let classKey: String
    let className: String
    let conf: Float
    /// Last box seen inside the zone, normalized image space.
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
    /// True when the bin was physically open at the time of deposit.
    var binWasOpen: Bool = true

    /// True when the detected category matches the bin the item went into.
    var isCorrect: Bool { BinGuide.info(for: classKey).id == zoneBinID }
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
}

/// Decides when an item counts as thrown away.
///
/// The unit of reasoning is the **object**, not the tracker id. `DetectionTracker` starts a
/// fresh id whenever the model blinks for more than `maxMisses` frames, and it refuses to
/// associate across a class change at all — so a single cup being carried to a bin can arrive
/// as three or four ids, some of them labelled differently. Treating each id as its own item
/// is what makes a momentary dropout look like a throw, and what makes the throw that follows
/// look like waste that materialised inside the bin.
///
/// So an object here spans ids. A new track that appears where a recently lost one was is
/// assumed to be the same thing, whatever the model now calls it, and inherits its history.
///
/// Three conditions have to hold for a deposit, each ruling out a different false positive:
///
/// - the object was seen **outside** every zone at some point in its life. Something the model
///   only ever saw inside a bin was never thrown in on camera — it is bin contents. An object
///   that was already being tracked keeps this credit through a blink, so reappearing inside
///   the zone is fine; only a never-tracked first sighting inside a zone is disqualified;
/// - it stayed inside one zone for `requiredDwellFrames` of frames the model actually saw, so
///   a hand passing over does not count;
/// - and it stayed gone for `reacquireGrace` after vanishing. A dropout that comes back is the
///   same object continuing, not a throw.
nonisolated final class ZoneDepositDetector {
    /// Detected frames an object must spend inside one zone before it can be credited.
    var requiredDwellFrames: Int = 3
    /// How long a vanished object is given to come back before it is judged. Also the delay
    /// between a real throw and it appearing in the log.
    var reacquireGrace: CFAbsoluteTime = 1.4
    /// How far a reappearing box may sit from where the object was lost, in normalized
    /// image widths, at the instant it vanishes.
    var reacquireRadius: CGFloat = 0.10
    /// Extra search radius per second missing. Sized so a carry from the mid-frame gap
    /// into a bin during a short blink still stitches; a 0.4s dropout can cover ~0.3.
    var reacquireDriftPerSecond: CGFloat = 0.55
    /// Ceiling so a long dropout cannot claim a box on the far side of the frame.
    var reacquireMaxRadius: CGFloat = 0.35

    private struct Sighting {
        var center: CGPoint
        var box: CGRect
        var classKey: String
        var className: String
        var conf: Float
    }

    private final class TrackedObject {
        let id = UUID()
        var trackID: Int
        var trackSegments = 1
        /// Cumulative confidence per class, so a flicker to the wrong label does not
        /// outvote a steady reading.
        var classWeights: [String: (className: String, weight: Float, conf: Float)] = [:]
        var everSeenOutside = false
        var zoneID: UUID?
        var zoneName = ""
        var zoneBinID = ""
        var dwell = 0
        var last: Sighting
        /// Last sighting that was inside a zone, which is what a deposit reports.
        var lastInZone: Sighting?
        var missingSince: CFAbsoluteTime?

        init(trackID: Int, sighting: Sighting) {
            self.trackID = trackID
            self.last = sighting
        }

        func note(_ sighting: Sighting) {
            last = sighting
            let existing = classWeights[sighting.classKey]
            classWeights[sighting.classKey] = (
                className: sighting.className,
                weight: (existing?.weight ?? 0) + sighting.conf,
                conf: sighting.conf
            )
        }

        /// The class with the most confidence behind it across the object's whole life.
        var verdictClass: (key: String, name: String, conf: Float) {
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
        closedZoneIDs: Set<UUID> = [],
        timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> ZoneFrameResult {
        guard !zones.isEmpty else {
            reset()
            return ZoneFrameResult()
        }

        var seenThisFrame = Set<ObjectIdentifier>()
        var occupied = Set<UUID>()

        // Coasting boxes are dropped outright. The tracker keeps emitting a frozen box for
        // `maxMisses` frames after the model stops finding something, which matters here for
        // a reason that is easy to miss: on a class change the tracker cannot associate the
        // new label with the old track, so it coasts the old one *while* the new one is
        // already live. Both are in this array at once. Treating the frozen box as a sighting
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
            let sighting = Sighting(
                center: CGPoint(x: track.displayXywhn.midX, y: track.displayXywhn.midY),
                box: track.displayXywhn,
                classKey: track.classKey,
                className: track.className,
                conf: track.conf
            )
            let object = resolveObject(
                for: track,
                sighting: sighting,
                now: timestamp,
                claimed: seenThisFrame
            )
            seenThisFrame.insert(ObjectIdentifier(object))
            object.missingSince = nil
            object.note(sighting)

            guard let zone = zones.first(where: { $0.contains(sighting.center) }) else {
                // Outside every zone: this is what earns the right to be counted later.
                object.everSeenOutside = true
                object.zoneID = nil
                object.dwell = 0
                object.lastInZone = nil
                continue
            }

            occupied.insert(zone.id)
            object.lastInZone = sighting

            if object.zoneID != zone.id {
                object.zoneID = zone.id
                object.zoneName = zone.name
                object.zoneBinID = zone.binID
                object.dwell = 0
            }
            // Every frame that reaches here is one the model actually saw, so dwell only
            // ever counts real evidence.
            object.dwell += 1
        }

        // Anything not seen this frame starts, or continues, its reacquisition window.
        for object in objects where !seenThisFrame.contains(ObjectIdentifier(object)) {
            if object.missingSince == nil {
                object.missingSince = timestamp
            }
        }

        let settled = objects.filter { object in
            guard let missingSince = object.missingSince else { return false }
            return timestamp - missingSince >= reacquireGrace
        }
        var deposits: [ZoneDeposit] = []
        for object in settled {
            deposits.append(contentsOf: deposit(from: object, closedZoneIDs: closedZoneIDs))
        }
        if !settled.isEmpty {
            let dead = Set(settled.map(ObjectIdentifier.init))
            objects.removeAll { dead.contains(ObjectIdentifier($0)) }
            byTrackID = byTrackID.filter { !dead.contains(ObjectIdentifier($0.value)) }
        }

        var armedZoneIDs = Set<UUID>()
        var settlingZoneIDs = Set<UUID>()
        for object in objects {
            guard let zoneID = object.zoneID, object.dwell >= requiredDwellFrames else { continue }
            if object.missingSince == nil {
                armedZoneIDs.insert(zoneID)
            } else if object.everSeenOutside {
                settlingZoneIDs.insert(zoneID)
            }
        }

        return ZoneFrameResult(
            deposits: deposits.sorted { $0.trackID < $1.trackID },
            occupiedZoneIDs: occupied,
            armedZoneIDs: armedZoneIDs,
            settlingZoneIDs: settlingZoneIDs
        )
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

        let created = TrackedObject(trackID: track.id, sighting: sighting)
        objects.append(created)
        byTrackID[track.id] = created
        return created
    }

    private func deposit(from object: TrackedObject, closedZoneIDs: Set<UUID> = []) -> [ZoneDeposit] {
        guard object.everSeenOutside,
              let zoneID = object.zoneID,
              let inZone = object.lastInZone,
              object.dwell >= requiredDwellFrames
        else { return [] }

        let verdict = object.verdictClass
        let wasOpen = !closedZoneIDs.contains(zoneID)
        return [
            ZoneDeposit(
                id: object.id,
                trackID: object.trackID,
                classKey: verdict.key,
                className: verdict.name,
                conf: verdict.conf,
                boxXywhn: inZone.box,
                zoneID: zoneID,
                zoneName: object.zoneName,
                zoneBinID: object.zoneBinID,
                dwellFrames: object.dwell,
                trackSegments: object.trackSegments,
                classesSeen: object.classWeights.count,
                binWasOpen: wasOpen
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
