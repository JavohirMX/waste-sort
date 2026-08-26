import PhotosUI
import SwiftUI

// MARK: - Result and status cards

extension PCCSmokeTestView {
    var statusRow: some View {
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

    var imageCard: some View {
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
    var visionStatusCard: some View {
        PCCVisionStatusCard(
            busy: isJudging || isProbing,
            enabled: $visionAttemptsEnabled
        )
    }

    func progressCard(title: String, detail: String) -> some View {
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
    var textProbeSection: some View {
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
    var crossCheckSection: some View {
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

    var emptyState: some View {
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
    func judgmentCard(_ judgment: PCCArbiterService.SmokeJudgment) -> some View {
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

    func diagnostics(_ judgment: PCCArbiterService.SmokeJudgment) -> some View {
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

    func verdictRow(_ title: String, _ value: String) -> some View {
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

    func outcomeDescription(_ outcome: PCCVerdictRecord.Outcome) -> String {
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
}
