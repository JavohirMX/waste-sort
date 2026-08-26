import CoreGraphics
import Foundation

// MARK: - Feedback cues (throw previews + wrong-zone holds)

extension ZoneDepositDetector {
    func throwPreviewCue(
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

    func inZoneIncorrectCue(
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
    func noteWrongZoneOccupancy(
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

    func expireInZoneIncorrectIfNeeded(
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
}
