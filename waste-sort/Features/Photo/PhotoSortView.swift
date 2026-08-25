import PhotosUI
import SwiftUI

/// Diagnostic surface: photos are judged by Apple's Private Cloud Compute
/// ALONE — no on-device model, no belief engine, no fuser. Built to answer one
/// question with gallery images: does the PCC path work on this device?
/// Every attempt is recorded through the same arbiter pipeline the kiosk uses,
/// so what you see here is exactly what the live judge would get.
struct PhotoSortView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var pickerItem: PhotosPickerItem?
    @State private var sourceImage: UIImage?
    @State private var isJudging = false
    @State private var isProbing = false
    @State private var judgment: PCCArbiterService.SmokeJudgment?
    @State private var probeJudgment: PCCArbiterService.SmokeJudgment?
    @State private var afmJudgment: PCCArbiterService.SmokeJudgment?
    @State private var isCrossChecking = false
    @State private var afmJudge: PCCArbiterService?
    @State private var errorMessage: String?
    @State private var availability = PCCJudgeAvailability.current
    @State private var capabilitiesSummary: String?
    @State private var visionAttemptsEnabled = PCCVisionGate.enabled
    /// Distinct, growing track ids so repeated smoke tests never collide with
    /// the arbiter's one-request-per-track dedupe (live tracks use small ids).
    @State private var nextTrackID = 900_000
    @State private var judge: PCCArbiterService?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusRow

                    if let capabilitiesSummary {
                        Text("PCC capabilities: \(capabilitiesSummary)")
                            .font(.system(.caption, design: .default).monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(.body, design: .default))
                            .foregroundStyle(.red)
                    }

                    visionStatusCard

                    if let sourceImage {
                        imageCard
                    }

                    if isJudging {
                        progressCard(title: "Asking Private Cloud Compute…", detail: "Usually 1–8 s")
                    } else if let judgment {
                        judgmentCard(judgment)
                    } else if sourceImage != nil {
                        Text("Pick the photo again to judge it.")
                            .font(.system(.footnote, design: .default))
                            .foregroundStyle(.secondary)
                    } else {
                        emptyState
                    }

                    textProbeSection

                    crossCheckSection
                }
                .padding(20)
            }
            .background(Theme.photoBackground)
            .navigationTitle("PCC smoke test")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                        Label("Choose photo", systemImage: "photo.on.rectangle")
                            .font(.system(.body, design: .default).weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(BinGuide.organic.color, in: Capsule())
                    }
                    .disabled(isJudging || judge == nil)
                    .accessibilityHint("Opens the photo library to judge one image with Private Cloud Compute")
                }
            }
            .task {
                if judge == nil {
                    judge = PCCArbiterService(store: PCCRecordStore())
                }
                if #available(iOS 27.0, *), afmJudge == nil {
                    afmJudge = PCCArbiterService(
                        store: PCCRecordStore(),
                        transport: PCCTransportFactory.onDeviceTransport()
                    )
                }
                availability = PCCJudgeAvailability.current
                if #available(iOS 27.0, *) {
                    capabilitiesSummary = PCCTransportFactory.capabilitiesSummary()
                }
            }
            .onChange(of: pickerItem) { _, newItem in
                Task { await importPhoto(newItem) }
            }
        }
        .environment(\.hudTextScale, CGFloat(settings.hudTextScale))
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(availability.isReady ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            Text(availability.summary)
                .font(.system(.footnote, design: .default))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var imageCard: some View {
        Group {
            if let sourceImage {
                Image(uiImage: sourceImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// States the current vision situation plainly: this beta's PCC declares
    /// vision support but traps on any image attachment, so attempts are
    /// opt-in. The toggle is the only way a user re-arms the crash path (e.g.
    /// to re-test after a beta update).
    private var visionStatusCard: some View {
        PCCVisionStatusCard(
            busy: isJudging || isProbing,
            enabled: $visionAttemptsEnabled
        )
    }

    private func progressCard(title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(title)
                .font(.system(.subheadline, design: .default).weight(.medium))
            Text(detail)
                .font(.system(.caption, design: .default))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    /// Text-only PCC probe: same session/respond shape as the vision call but
    /// with NO attachment. If this succeeds while the image path traps, the
    /// attachment pipeline itself is the broken layer on this OS build.
    private var textProbeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await runTextProbe() }
            } label: {
                Label(
                    isProbing ? "Probing…" : "Run text-only probe",
                    systemImage: "antenna.radiowaves.left.and.right"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .disabled(isProbing || isJudging || judge == nil)

            if isProbing {
                progressCard(title: "Probing PCC without an image…", detail: "Usually 1–3 s")
            } else if let probeJudgment {
                let record = probeJudgment.record
                Group {
                    if probeJudgment.answered {
                        let reply = record.pccRawBinLabel ?? "?"
                        let latency = record.latencyMs ?? 0
                        Label(
                            "PCC reachable — replied “\(reply)” in \(latency) ms. The trap is specific to the image-attachment path.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Even the text-only probe failed", systemImage: "xmark.octagon.fill")
                                .foregroundStyle(.red)
                            Text(outcomeDescription(record.outcome))
                                .font(.system(.footnote, design: .default))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.system(.footnote, design: .default))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 4)
    }

    /// Control experiment for the PCC image path: same image, on-device
    /// model. The result card states the conclusion outright so the operator
    /// knows whether to blame the content or the PCC pipeline.
    private var crossCheckSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await runAFMCrossCheck() }
            } label: {
                Label(
                    isCrossChecking ? "Checking on-device model…" : "Cross-check same image on-device",
                    systemImage: "cpu"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .disabled(isCrossChecking || isJudging || isProbing || afmJudge == nil || sourceImage == nil)

            if isCrossChecking {
                progressCard(title: "Asking the on-device model…", detail: "Control experiment for the PCC path")
            } else if let afmJudgment {
                let record = afmJudgment.record
                Group {
                    if afmJudgment.answered {
                        Label(
                            "On-device model answered: \(record.pccRawBinLabel ?? "?") "
                                + "(\(record.latencyMs ?? 0) ms). The image content is fine — "
                                + "the rejection is specific to the PCC pipeline.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("The on-device model failed too", systemImage: "xmark.octagon.fill")
                                .foregroundStyle(.orange)
                            Text(outcomeDescription(record.outcome))
                                .font(.system(.footnote, design: .default))
                                .foregroundStyle(.secondary)
                            Text("Try a different photo — the content itself may be tripping guardrails.")
                                .font(.system(.footnote, design: .default))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.system(.footnote, design: .default))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Text("Choose photo")
                    .font(.system(.headline, design: .default))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(BinGuide.organic.color)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(isJudging || judge == nil)

            Text("Diagnostic mode: photos are judged ONLY by Apple's Private Cloud Compute — no on-device model runs. "
                + "Start with the text-only probe below; it is the crash-safe health check on this iOS beta.")
                .font(.system(.footnote, design: .default))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func judgmentCard(_ judgment: PCCArbiterService.SmokeJudgment) -> some View {
        let record = judgment.record
        if judgment.answered {
            let bin = BinGuide.bin(id: record.pccBinID ?? BinGuide.unknown.id)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: bin.symbolName)
                        .font(.title)
                        .foregroundStyle(bin.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bin.displayName)
                            .font(.system(.title2, design: .default).weight(.bold))
                            .foregroundStyle(bin.color)
                        Text("PCC verdict")
                            .font(.system(.caption, design: .default))
                            .foregroundStyle(.secondary)
                    }
                }
                verdictRow("Raw label", record.pccRawBinLabel ?? "—")
                verdictRow("Material", record.material ?? "—")
                if let rationale = record.reasoningSummary, !rationale.isEmpty {
                    verdictRow("Why", rationale)
                }
                verdictRow("Agrees with device", record.agreesWithEngine.map { $0 ? "yes" : "no" } ?? "—")
                diagnostics(judgment)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bin.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label("PCC did not return an answer", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.headline, design: .default))
                    .foregroundStyle(.orange)
                Text(outcomeDescription(record.outcome))
                    .font(.system(.body, design: .default))
                Text("Device status: \(judgment.availabilitySummary)")
                    .font(.system(.footnote, design: .default))
                    .foregroundStyle(.secondary)
                diagnostics(judgment)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func diagnostics(_ judgment: PCCArbiterService.SmokeJudgment) -> some View {
        let record = judgment.record
        return VStack(alignment: .leading, spacing: 4) {
            if let latency = record.latencyMs {
                verdictRow("Latency", "\(latency) ms")
            }
            if let quota = record.quotaStateAtCall {
                verdictRow("Quota", quota)
            }
            verdictRow("Recorded", "yes (pipeline: \(record.pipeline))")
        }
        .padding(.top, 4)
    }

    private func verdictRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(.subheadline, design: .default))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .default).weight(.medium))
                .multilineTextAlignment(.trailing)
        }
    }

    private func outcomeDescription(_ outcome: PCCVerdictRecord.Outcome) -> String {
        switch outcome {
        case .timeout:
            return "The request timed out after \(Int(WasteSortConfig.defaultPCCTimeoutSeconds)) s. Check the network and try again."
        case .skippedQuota:
            return "The daily Private Cloud Compute quota is exhausted on this device. It resets automatically; "
                + "the exact reset time appears in Settings → PCC second opinion → Status."
        case .skippedUnavailable(let reason):
            return "PCC is unavailable on this device: \(reason). Check the checklist in RUNBOOK.md Part A "
                + "(iOS 27, Apple Intelligence on, entitlement attached)."
        case .error(let message):
            return "The request failed: \(message). Repeated failures trip the circuit breaker for "
                + "\(Int(WasteSortConfig.defaultPCCBreakerCooldownSeconds)) s."
        case .cropFailed:
            return "The image could not be prepared for the model."
        case .skippedOffline:
            return "The device appears to be offline."
        case .skippedDisabled:
            return "The PCC judge toggle is off."
        case .answered:
            return "Answered."
        }
    }

    private func importPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else {
                errorMessage = "Could not read that photo."
                return
            }
            await judgePhoto(image)
        } catch {
            errorMessage = "Could not read that photo."
        }
    }

    private func judgePhoto(_ image: UIImage) async {
        guard let judge else {
            errorMessage = "Judge is not ready yet — try again in a moment."
            return
        }
        errorMessage = nil
        judgment = nil
        sourceImage = image
        isJudging = true
        defer { isJudging = false }

        guard let frameCG = UprightFrameImage.cgImage(from: image) else {
            errorMessage = "Could not read that image."
            return
        }
        let crop = smokeCrop(from: frameCG)
        nextTrackID += 1
        let context = ArbiterRequestContext(
            trackId: nextTrackID,
            sessionId: "photo-smoke",
            yoloLabel: "photo_smoke",
            yoloConfidence: 0,
            beliefUncertain: false,
            beliefMargin: 0,
            engineBinID: BinGuide.unknown.id,
            pipeline: "photo-smoke",
            triggeredAt: Date()
        )
        judgment = await judge.smokeJudge(context, crop: crop)
        availability = PCCJudgeAvailability.current
    }

    /// Whole-frame "crop", downscaled to the SAME size the live judge sends
    /// (448 px). Measured on the iOS 27 sim: 512 px answered in ~1.3 s while
    /// 1024 px took 6–8 s and straddled the 10 s timeout — the smoke screen
    /// must exercise the shape production uses, not a heavier one.
    private func smokeCrop(from frameCG: CGImage) -> CGImage {
        ItemCropper.crop(
            frameCG,
            to: CGRect(x: 0, y: 0, width: 1, height: 1),
            padding: WasteSortConfig.defaultPCCCropPadding,
            maximumSide: WasteSortConfig.defaultPCCCropMaximumSide,
            minimumSide: WasteSortConfig.defaultPCCCropMinimumPixels
        ) ?? frameCG
    }

    /// Decisive bisection: the SAME prompt and normalized image sent to the
    /// on-device model. On-device answer + PCC rejection = the image content
    /// is fine and the PCC image pipeline is what rejects it (beta
    /// limitation, worth a Feedback). Both fail = the content itself trips
    /// guardrails; try a different photo.
    private func runAFMCrossCheck() async {
        guard let afmJudge, let sourceImage else { return }
        afmJudgment = nil
        isCrossChecking = true
        defer { isCrossChecking = false }
        guard let frameCG = UprightFrameImage.cgImage(from: sourceImage) else {
            errorMessage = "Could not read that image."
            return
        }
        nextTrackID += 1
        let context = ArbiterRequestContext(
            trackId: nextTrackID,
            sessionId: "photo-smoke",
            yoloLabel: "photo_smoke",
            yoloConfidence: 0,
            beliefUncertain: false,
            beliefMargin: 0,
            engineBinID: BinGuide.unknown.id,
            pipeline: "photo-smoke-afm",
            triggeredAt: Date()
        )
        afmJudgment = await afmJudge.smokeJudge(context, crop: smokeCrop(from: frameCG))
        availability = PCCJudgeAvailability.current
    }

    private func runTextProbe() async {
        guard let judge else { return }
        probeJudgment = nil
        isProbing = true
        defer { isProbing = false }

        // Tiny placeholder bitmap: the pipeline requires a crop to record, but
        // the text-probe transport never attaches it.
        let probeCrop = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ).flatMap { $0.makeImage() }

        nextTrackID += 1
        let context = ArbiterRequestContext(
            trackId: nextTrackID,
            sessionId: "photo-smoke",
            yoloLabel: PCCTextProbe.label,
            yoloConfidence: 0,
            beliefUncertain: false,
            beliefMargin: 0,
            engineBinID: BinGuide.unknown.id,
            pipeline: "photo-smoke",
            triggeredAt: Date()
        )
        probeJudgment = await judge.smokeJudge(context, crop: probeCrop)
        availability = PCCJudgeAvailability.current
    }
}

/// Opt-in switch for image judgments, with the honest state of the vision
/// path spelled out. Extracted from the smoke screen to keep that struct
/// under its size budget; the copy doubles as the operator's memory of WHY
/// the default is off on this iOS beta.
private struct PCCVisionStatusCard: View {
    let busy: Bool
    @Binding var enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Attempt image judgments", isOn: Binding(
                get: { enabled },
                set: { on in
                    PCCVisionGate.setEnabled(on)
                    enabled = on
                }
            ))
            .disabled(busy)

            if enabled {
                Label(
                    "Image attempts are ON. On this iOS beta the framework traps (app crash) when PCC receives an image — "
                        + "that is an Apple bug, not a setup problem. The text probe below stays safe.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(.footnote, design: .default))
                .foregroundStyle(.orange)
            } else {
                Label(
                    "Image judgments are OFF: this iOS beta crashes on PCC image attachments even though the runtime "
                        + "claims vision support. Text probing works — use it to confirm PCC health. Turn the toggle on "
                        + "only to re-test after a beta update.",
                    systemImage: "photo.slash"
                )
                .font(.system(.footnote, design: .default))
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
