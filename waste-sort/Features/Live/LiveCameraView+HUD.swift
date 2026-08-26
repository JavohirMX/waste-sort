import SwiftUI
import UIKit

// MARK: - HUD chrome (category bar, banners, chips, stats tab)

extension LiveCameraView {
    /// The top stays clear while calibrating so nothing covers a zone.
    @ViewBuilder var topHUD: some View {
        if !zoneStore.isEditingZones {
            CategoryBar(
                bins: binStyle.orderedBins,
                counts: counts,
                ctaStyle: settings.ctaStyle,
                throwFeedback: throwFeedbackGate.feedback,
                throwFeedbackToken: throwFeedbackGate.token,
                onTripleTap: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeInOut(duration: 0.35)) {
                        showSettings = true
                    }
                }
            )
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.categoryBarTopGap)

        if let tagFailure = tagFailureReason {
            TagFailureBanner(reason: tagFailure)
                .padding(.horizontal, Theme.hudInset)
                .padding(.top, 6)
        }

        if let barcode = barcodeHint {
            BarcodeHintChip(barcode: barcode)
                .padding(.horizontal, Theme.hudInset)
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }

        if let drop = lastDropNotice {
            DepositDropChip(drop: drop)
                .padding(.horizontal, Theme.hudInset)
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
        }
    }

    @ViewBuilder var bottomHUD: some View {
        if zoneStore.isEditingZones {
            ZoneEditBar(
                zones: zoneStore.zones,
                selectedZoneID: $selectedZoneID,
                onReset: {
                    zoneStore.resetToDefaults(
                        rotation: overlayRotation,
                        mirror: settings.liveMirror
                    )
                },
                onDone: { zoneStore.isEditingZones = false }
            )
            .padding(.horizontal, Theme.hudInset)
            .padding(.bottom, Theme.hudInset)
        } else {
            if showsCleanableHint {
                CleanableHintChip()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Theme.hudInset)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 8) {
                    if settings.showFPS {
                        Text("\(fps) FPS")
                            .font(.system(.caption, design: .default).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                            .accessibilityLabel("\(fps) frames per second")
                    }
                    if settings.showLastDepositOnLive, let last = history.events.first {
                        LastDepositChip(
                            record: last,
                            isFresh: freshDepositID == last.id,
                            onTap: { showHistory = true }
                        )
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .id(last.id)
                    }
                    if tracks.contains(where: {
                        !$0.isCoasting && BinGuide.isDirtyRecyclable($0.classKey)
                    }) {
                        DirtyRecyclableSuggestionChip()
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    if settings.foundationConfirmationEnabled,
                       settings.foundationVerdictLogEnabled,
                       let verdict = verdictLog.records.first
                    {
                        LastVerdictChip(
                            record: verdict,
                            isFresh: freshVerdictID == verdict.id,
                            onTap: { showVerdicts = true }
                        )
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .id(verdict.id)
                    }
                }
                .padding(.leading, Theme.hudInset)
                Spacer(minLength: 0)
                statsGlassButton
            }
            .animation(
                .spring(response: 0.35, dampingFraction: 0.7),
                value: tracks.contains(where: { $0.beliefUncertain })
            )
            .animation(
                .spring(response: 0.35, dampingFraction: 0.7),
                value: history.events.first?.id
            )
            .animation(
                .spring(response: 0.35, dampingFraction: 0.7),
                value: tracks.contains(where: {
                    !$0.isCoasting && BinGuide.isDirtyRecyclable($0.classKey)
                })
            )
            .animation(
                .spring(response: 0.35, dampingFraction: 0.7),
                value: verdictLog.records.first?.id
            )
            .animation(.easeOut(duration: Theme.animationDuration), value: freshDepositID)
            .animation(.easeOut(duration: Theme.animationDuration), value: freshVerdictID)
            .padding(.bottom, Theme.hudInset)
        }
    }

    var statsGlassButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.35)) {
                showStats = true
            }
        } label: {
            GlassChrome.edgeTabLabel(edge: .trailing) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Waste stats")
        .accessibilityHint("Opens stats.")
    }
}
