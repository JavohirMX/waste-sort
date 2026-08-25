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
    @State private var judgment: PCCArbiterService.SmokeJudgment?
    @State private var errorMessage: String?
    @State private var availability = PCCJudgeAvailability.current
    /// Distinct, growing track ids so repeated smoke tests never collide with
    /// the arbiter's one-request-per-track dedupe (live tracks use small ids).
    @State private var nextTrackID = 900_000
    @State private var judge: PCCArbiterService?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusRow

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(.body, design: .default))
                            .foregroundStyle(.red)
                    }

                    if let sourceImage {
                        imageCard
                    }

                    if isJudging {
                        ProgressView("Asking Private Cloud Compute…\n(can take 5–15 s)")
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    } else if let judgment {
                        judgmentCard(judgment)
                    } else if sourceImage == nil {
                        emptyState
                    }
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
                availability = PCCJudgeAvailability.current
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
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
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

            Text("Diagnostic mode: the photo is judged ONLY by Apple's Private Cloud Compute. No on-device model runs. Use any gallery image of a waste item.")
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
            return "The daily Private Cloud Compute quota is exhausted on this device. It resets automatically; the exact reset time appears in Settings → PCC second opinion → Status."
        case .skippedUnavailable(let reason):
            return "PCC is unavailable on this device: \(reason). Check the checklist in RUNBOOK.md Part A (iOS 27, Apple Intelligence on, entitlement attached)."
        case .error(let message):
            return "The request failed: \(message). Repeated failures trip the circuit breaker for \(Int(WasteSortConfig.defaultPCCBreakerCooldownSeconds)) s."
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
        // Whole-frame "crop", downscaled — the model sees the full photo.
        let crop = ItemCropper.crop(
            frameCG,
            to: CGRect(x: 0, y: 0, width: 1, height: 1),
            padding: 0,
            maximumSide: 1024,
            minimumSide: 96
        ) ?? frameCG

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
}
