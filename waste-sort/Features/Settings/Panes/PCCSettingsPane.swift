import SwiftUI

struct PCCSettingsPane: View {
    @EnvironmentObject private var settings: AppSettings
    /// PCC judge status + export state (specs/001-pcc-uncertainty-judge).
    @State private var pccJudgeAvailability = PCCJudgeAvailability.current
    @State private var pccExportStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var pccExportEnd = Date()
    @State private var pccExportMessage: String?
    @State private var pccExportURL: URL?
    @State private var pccSuggestions: [SuggestedOverride] = []
    @State private var pccAppliedOverrides: [AppliedBinOverride] = []
    @State private var pccAnalyzedRecords = 0
    @State private var pccAnalyzedClasses = 0
    @State private var showSmokeTest = false

    var body: some View {
        Form {
            judgeSection
            exportSection
            correctionsSection
        }
        .font(.system(.body, design: .default))
        .navigationDestination(isPresented: $showSmokeTest) {
            PCCSmokeTestView()
                .environmentObject(settings)
        }
    }

    @ViewBuilder
    private var judgeSection: some View {
        Section {
            Toggle("Silent PCC judge", isOn: $settings.pccJudgeEnabled)
            Toggle("Audit confident verdicts", isOn: $settings.pccConfidentAuditEnabled)

            LabeledContent("Status") {
                Text(pccJudgeAvailability.summary)
                    .foregroundStyle(pccJudgeAvailability.isReady ? Color.green : Color.secondary)
                    .multilineTextAlignment(.trailing)
            }

            Button("Run smoke test") { showSmokeTest = true }
        } header: {
            Text("PCC second opinion")
                .foregroundStyle(BinGuide.cleanInorganic.color)
        } footer: {
            Text(
                "When an item is guided to residual because the engine is unsure, Apple's Private Cloud Compute model "
                    + "silently judges it too. With audits on, it also double-checks confident verdicts — nothing on "
                    + "screen changes either way; answers and crops are logged so training can compare them against "
                    + "what YOLO believed. Unsure items are always judged first; audits use whatever quota remains."
            )
        }
    }

    @ViewBuilder
    private var exportSection: some View {
        Section {
            DatePicker("From", selection: $pccExportStart, displayedComponents: [.date, .hourAndMinute])
            DatePicker("To", selection: $pccExportEnd, displayedComponents: [.date, .hourAndMinute])

            Button("Export judgments for range") {
                exportPCCJudgments()
            }

            if let pccExportMessage {
                Text(pccExportMessage)
                    .font(.system(.footnote, design: .default))
                    .foregroundStyle(.secondary)
            }

            if let pccExportURL {
                ShareLink("Share exported bundle", item: pccExportURL)
            }
        } header: {
            Text("Fine-tuning exports")
                .foregroundStyle(BinGuide.organic.color)
        } footer: {
            Text(
                "Exports bundle the recorded crops + labels ready for YOLO fine-tuning. "
                    + "Ranges are minute-precise so sessions can be sliced by hour."
            )
        }
    }

    @ViewBuilder
    private var correctionsSection: some View {
        Section {
            Button("Analyze judge records") {
                refreshPCCCorrections()
            }
            .onAppear(perform: refreshPCCCorrections)

            if pccSuggestions.isEmpty {
                Text(pccEmptyStateMessage)
                    .font(.system(.footnote, design: .default))
                    .foregroundStyle(.secondary)
            }
            ForEach(pccSuggestions) { suggestion in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.itemClass)
                        Text(pccSuggestionCaption(suggestion))
                            .font(.system(.caption, design: .default))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Apply") {
                        AppliedBinOverrides.shared.apply(suggestion)
                        refreshPCCCorrections()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            ForEach(pccAppliedOverrides) { applied in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(applied.itemClass)
                        Text(pccAppliedCaption(applied))
                            .font(.system(.caption, design: .default))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    let bin = BinGuide.bin(id: applied.binID)
                    Image(systemName: bin.symbolName)
                        .foregroundStyle(bin.color)
                }
            }
            .onDelete(perform: removePCCCorrections)

            if !pccAppliedOverrides.isEmpty {
                Button("Remove all corrections", role: .destructive) {
                    AppliedBinOverrides.shared.removeAll()
                    refreshPCCCorrections()
                }
            }
        } header: {
            Text("Learned corrections")
                .foregroundStyle(BinGuide.cleanInorganic.color)
        } footer: {
            Text(
                "Mines the judge records for dominant PCC-vs-device disagreements and applies them as "
                    + "routing overrides. Overrides decorate lookups only — the static map stays untouched "
                    + "and any correction can be removed instantly."
            )
        }
    }

    private func refreshPCCCorrections() {
        let interval = DateInterval(start: .distantPast, end: Date())
        let records = PCCRecordStore().records(in: interval).filter { !$0.isDiagnostic }
        pccSuggestions = PCCPolicyAnalyzer.suggestions(from: records)
        pccAppliedOverrides = AppliedBinOverrides.shared.all()
        pccAnalyzedRecords = records.count { $0.outcome == .answered && !$0.mappingFailed }
        pccAnalyzedClasses = Set(
            records
                .filter { $0.outcome == .answered && !$0.mappingFailed }
                .map { BinGuide.normalizedKey($0.yoloLabel) }
        ).count
    }

    private var pccEmptyStateMessage: String {
        if pccAnalyzedRecords == 0 {
            return "No answered judgments recorded yet. The judge only logs items that "
                + "were guided to residual while unsure — feed it ambiguous packaging "
                + "and check the status row above."
        }
        return "No corrections suggested yet — \(pccAnalyzedRecords) answered judgment"
            + "\(pccAnalyzedRecords == 1 ? "" : "s") across \(pccAnalyzedClasses) class"
            + "\(pccAnalyzedClasses == 1 ? "" : "es") analyzed. A suggestion needs at "
            + "least 12 agreeing judgments that dispute the class's current routing."
    }

    private func removePCCCorrections(at offsets: IndexSet) {
        for index in offsets {
            AppliedBinOverrides.shared.remove(itemClassKey: pccAppliedOverrides[index].itemClass)
        }
        refreshPCCCorrections()
    }

    private func pccSuggestionCaption(_ suggestion: SuggestedOverride) -> String {
        let percent = Int((suggestion.agreementRate * 100).rounded())
        let from = BinGuide.staticInfo(for: suggestion.id).displayName
        let to = BinGuide.bin(id: suggestion.suggestedBinID).displayName
        return "\(from) → \(to) · \(suggestion.sampleCount) judgments · \(percent)% agree"
    }

    private func pccAppliedCaption(_ applied: AppliedBinOverride) -> String {
        let percent = Int((applied.agreementRate * 100).rounded())
        return "→ \(BinGuide.bin(id: applied.binID).displayName) · "
            + "\(applied.sampleCount) judgments · \(percent)% agree"
    }

    private func exportPCCJudgments() {
        // Minute precision, no day-snapping: operators slice sessions by
        // hour when assembling teaching datasets.
        let start = min(pccExportStart, pccExportEnd)
        let end = max(pccExportStart, pccExportEnd)
        let interval = DateInterval(start: start, end: end)
        do {
            let bundle = try PCCDatasetExporter.export(
                records: interval,
                from: PCCRecordStore()
            )
            pccExportMessage = "Exported \(bundle.recordCount) records."
            pccExportURL = bundle.directoryURL
        } catch PCCDatasetExporter.ExportError.nothingToExport {
            pccExportMessage = "No judgments recorded in that range yet."
            pccExportURL = nil
        } catch {
            pccExportMessage = "Export failed: \(error.localizedDescription)"
            pccExportURL = nil
        }
    }
}
