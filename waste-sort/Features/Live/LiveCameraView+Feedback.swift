import SwiftUI
import UIKit
import UltralyticsYOLO

// MARK: - Detection ingestion, zone editing, and feedback presentation

extension LiveCameraView {
    /// Per-frame state pump: mirrors pipeline results into @State and fires
    /// the deposit/feedback side effects. Runs on the main actor via the
    /// detection callback.
    func handleDetectionResult(
        result: YOLOResult,
        tracked: [TrackedDetection],
        zoneFrame: ZoneFrameResult,
        openness: BinOpennessSnapshot,
        confirmed: ConfirmationFrame,
        verdicts: [FoundationVerdictRecord]
    ) {
        let tagFrame = openness.tag
        if let measured = fpsMonitor.tick(reportedFPS: result.fps) {
            fps = measured
        }
        imageSize = result.orig_shape
        tracks = tracked
        if confirmationFrame != confirmed {
            confirmationFrame = confirmed
        }
        if !verdicts.isEmpty {
            verdictLog.append(verdicts)
            flashVerdict()
        }
        detectedTags = tagFrame.detectedTags
        tagStatuses = tagFrame.statuses
        tagStats = tagFrame.detectorStats
        detectedTagFailure = tagFrame.detectorFailureReason
        if markerFrame != openness.marker {
            markerFrame = openness.marker
        }
        if occupiedZoneIDs != zoneFrame.occupiedZoneIDs {
            occupiedZoneIDs = zoneFrame.occupiedZoneIDs
        }
        if armedZoneIDs != zoneFrame.armedZoneIDs {
            armedZoneIDs = zoneFrame.armedZoneIDs
        }
        if settlingZoneIDs != zoneFrame.settlingZoneIDs {
            settlingZoneIDs = zoneFrame.settlingZoneIDs
        }
        if !zoneFrame.cancelledThrowFeedbackIDs.isEmpty {
            cancelThrowFeedback(ids: zoneFrame.cancelledThrowFeedbackIDs)
        }
        for cue in zoneFrame.throwFeedbackCues {
            presentThrowFeedback(cue)
        }
        if !zoneFrame.deposits.isEmpty {
            history.append(zoneFrame.deposits)
            flash(zoneFrame.deposits)
        }
        if let drop = zoneFrame.drops.last {
            showDropNotice(drop)
        }

        var nextCounts: [String: Int] = [:]
        for track in tracked where !track.isCoasting {
            // Unsure items light up the fallback bin so the bar stays honest;
            // dirty recyclable lights residual and recyclable together.
            let binIDs = track.beliefUncertain
                ? [BinGuide.fallbackBinID]
                : BinGuide.barBinIDs(for: track.classKey)
            for binID in binIDs where binID != BinGuide.unknown.id {
                nextCounts[binID, default: 0] += 1
            }
        }
        if nextCounts != counts {
            counts = nextCounts
        }
    }

    /// Writes down the chroma the camera is actually reporting for each visible strip.
    ///
    /// The palette ships with the chroma of ideal ink, which is not what comes back from a
    /// particular printer, under a particular lamp, through a particular camera's white
    /// balance. Widening the match tolerance to cover that gap would start admitting colored
    /// rubbish; measuring the real thing once does not.
    ///
    /// Only strips whose rhythm was fully read are learned from. A degraded reading was named
    /// by the very colour we would be storing, so learning from it would let the palette drift
    /// wherever the first mistake pointed.
    func calibrateMarkers() {
        var learned = 0
        for detection in markerFrame.detections {
            guard !detection.isDegraded,
                  let slot = detection.slot(style: markerStore.style)
            else { continue }
            markerStore.calibrate(slot: slot.index, chroma: detection.chroma)
            learned += 1
        }
        guard learned > 0 else { return }
        HapticsService.shared.fire(.mediumImpact)
    }

    func moveCorner(zoneID: UUID, index: Int, point: CGPoint) {
        guard var zone = zoneStore.zones.first(where: { $0.id == zoneID }),
              zone.corners.indices.contains(index)
        else { return }
        zone.corners[index] = point
        zoneStore.update(zone)
    }

    func moveZone(zoneID: UUID, corners: [CGPoint]) {
        guard var zone = zoneStore.zones.first(where: { $0.id == zoneID }) else { return }
        zone.corners = corners
        zoneStore.update(zone)
    }

    /// Same beat as a deposit landing, minus the haptic — the model answers often enough
    /// that buzzing every time would be noise.
    func flashVerdict() {
        let latest = verdictLog.records.first?.id
        withAnimation(.easeOut(duration: Theme.animationDuration)) {
            freshVerdictID = latest
        }
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeOut(duration: Theme.animationDuration)) {
                if freshVerdictID == latest { freshVerdictID = nil }
            }
        }
    }

    /// Flashes the receiving zone outline on a confirmed deposit.
    func flash(_ deposits: [ZoneDeposit]) {
        let zoneIDs = Set(deposits.map(\.zoneID))
        let latest = history.events.first?.id
        withAnimation(.easeOut(duration: Theme.animationDuration)) {
            flashedZoneIDs.formUnion(zoneIDs)
            freshDepositID = latest
        }
        announceAndVibrate(deposits)
        if let deposit = deposits.last {
            if previewedFeedbackIDs.contains(deposit.id) {
                releasePersistedFeedback(for: deposit)
            } else {
                presentThrowFeedback(
                    ThrowFeedbackCue(
                        objectID: deposit.id,
                        zoneBinID: deposit.zoneBinID,
                        isCorrect: deposit.isCorrect,
                        persistWhilePresent: false
                    )
                )
            }
            previewedFeedbackIDs.remove(deposit.id)
        }
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: Theme.animationDuration)) {
                flashedZoneIDs.subtract(zoneIDs)
                if freshDepositID == latest { freshDepositID = nil }
            }
        }
    }

    /// Overlays the destination segment; a newer throw cancels the dismiss.
    func presentThrowFeedback(_ cue: ThrowFeedbackCue) {
        let feedback = ThrowFeedback.from(cue)
        if throwFeedbackGate.objectID == cue.objectID, throwFeedbackGate.feedback == feedback {
            return
        }
        var gate = throwFeedbackGate
        let token = gate.present(
            feedback,
            objectID: cue.objectID,
            persistWhilePresent: cue.persistWhilePresent
        )
        withAnimation(.easeOut(duration: Theme.animationDuration)) {
            throwFeedbackGate = gate
        }
        previewedFeedbackIDs.insert(cue.objectID)
        if settings.throwFeedbackSoundsEnabled {
            ThrowFeedbackPlayer.shared.play(correct: cue.isCorrect)
        }
        if !cue.persistWhilePresent {
            scheduleThrowFeedbackDismiss(token: token)
        }
    }

    func cancelThrowFeedback(ids: Set<UUID>) {
        previewedFeedbackIDs.subtract(ids)
        guard let current = throwFeedbackGate.objectID, ids.contains(current) else { return }
        withAnimation(.easeOut(duration: Theme.animationDuration)) {
            throwFeedbackGate.dismiss(objectID: current)
        }
    }

    /// Shows why the last throw was not counted, then lets it fade. A throw
    /// that silently vanished used to look like a broken kiosk.
    func showDropNotice(_ drop: DepositDrop) {
        dropNoticeClearTask?.cancel()
        withAnimation(.easeOut(duration: Theme.animationDuration)) {
            lastDropNotice = drop
        }
        dropNoticeClearTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: Theme.animationDuration)) {
                lastDropNotice = nil
            }
        }
    }

    /// After a real deposit, an in-zone banner that was holding starts its 1.8s fade.
    func releasePersistedFeedback(for deposit: ZoneDeposit) {
        guard throwFeedbackGate.objectID == deposit.id, throwFeedbackGate.persistWhilePresent else {
            return
        }
        let token = throwFeedbackGate.token
        var gate = throwFeedbackGate
        gate.markEphemeral()
        throwFeedbackGate = gate
        scheduleThrowFeedbackDismiss(token: token)
    }

    func scheduleThrowFeedbackDismiss(token: UInt64) {
        Task {
            try? await Task.sleep(for: .seconds(Theme.throwFeedbackDuration))
            withAnimation(.easeOut(duration: Theme.animationDuration)) {
                throwFeedbackGate.dismissIfCurrent(token: token)
            }
        }
    }

    /// Spoken + tactile confirmation per deposit; hands-free kiosks rely on this.
    func announceAndVibrate(_ deposits: [ZoneDeposit]) {
        var announcedBins = Set<String>()
        for deposit in deposits {
            if deposit.isCorrect {
                HapticsService.shared.fire(.depositCorrect(binID: deposit.zoneBinID))
            } else {
                HapticsService.shared.fire(.depositIncorrect)
            }
            guard settings.voiceGuidanceEnabled else { continue }
            let bin = BinGuide.info(for: deposit.classKey)
            guard bin != BinGuide.unknown, !announcedBins.contains(bin.id) else { continue }
            announcedBins.insert(bin.id)
            if deposit.wasUncertain {
                SpeechAnnouncer.shared.speak(
                    GuidancePhrases.uncertainDepositConfirmation(displayName: bin.displayName)
                )
            } else {
                SpeechAnnouncer.shared.speak(GuidancePhrases.depositConfirmation(displayName: bin.displayName))
            }
        }
    }
}
