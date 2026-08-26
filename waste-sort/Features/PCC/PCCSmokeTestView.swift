import PhotosUI
import SwiftUI

/// Diagnostic surface: photos are judged by Apple's Private Cloud Compute
/// ALONE — no on-device model, no belief engine, no fuser. Built to answer one
/// question with gallery images: does the PCC path work on this device?
/// Every attempt is recorded through the same arbiter pipeline the kiosk uses,
/// so what you see here is exactly what the live judge would get.
struct PCCSmokeTestView: View {
    @EnvironmentObject private var settings: AppSettings
    @State var pickerItem: PhotosPickerItem?
    @State var sourceImage: UIImage?
    @State var isJudging = false
    @State var isProbing = false
    @State var judgment: PCCArbiterService.SmokeJudgment?
    @State var probeJudgment: PCCArbiterService.SmokeJudgment?
    @State var afmJudgment: PCCArbiterService.SmokeJudgment?
    @State var isCrossChecking = false
    @State var afmJudge: PCCArbiterService?
    @State var errorMessage: String?
    @State var availability = PCCJudgeAvailability.current
    @State var capabilitiesSummary: String?
    @State var visionAttemptsEnabled = PCCVisionGate.enabled
    /// Distinct, growing track ids so repeated smoke tests never collide with
    /// the arbiter's one-request-per-track dedupe (live tracks use small ids).
    @State var nextTrackID = 900_000
    @State var judge: PCCArbiterService?

    var body: some View {
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
        .environment(\.hudTextScale, CGFloat(settings.hudTextScale))
    }
}

/// Opt-in switch for image judgments, with the honest state of the vision
/// path spelled out. Extracted from the smoke screen to keep that struct
/// under its size budget; the copy doubles as the operator's memory of WHY
struct PCCVisionStatusCard: View {
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
                    "Image attempts are ON — verified working on iOS 27 beta 6 with a matched Xcode "
                        + "(~1–2 s verdicts). If a future beta reintroduces the crash, switch this OFF: "
                        + "the app then records honest skipped entries instead of crashing.",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.system(.footnote, design: .default))
                .foregroundStyle(.green)
            } else {
                Label(
                    "Image judgments are OFF (kill switch). Every image request records a skipped "
                        + "entry instead of calling PCC; the text-only probe below still works. Turn ON "
                        + "to judge images.",
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
