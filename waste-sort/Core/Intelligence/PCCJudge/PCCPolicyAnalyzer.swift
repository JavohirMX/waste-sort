import Foundation

/// A statistically-supported bin-routing correction mined from judge records,
/// awaiting an operator's explicit Apply (specs/002 FR-7: nothing applies
/// itself).
nonisolated struct SuggestedOverride: Equatable, Identifiable, Sendable {
    nonisolated enum Direction: Equatable, Sendable {
        /// PCC dominantly points at residual; the static map does not.
        case intoResidual
        /// The static map says residual; PCC dominantly disagrees.
        case outOfResidual
        /// Any other static-map change (e.g. organic ↔ clean_inorganic).
        case lateral
    }

    /// Normalized class key; also the stable identity across analyses.
    let id: String
    /// Label as first seen in records, for display.
    let itemClass: String
    let suggestedBinID: String
    let currentStaticBinID: String
    let sampleCount: Int
    let agreementRate: Double
    let direction: Direction
}

/// Pure mining of answered judge records into override suggestions. No I/O,
/// no clocks — same records in, same suggestions out (constitution V).
///
/// Suggestions compare PCC's dominant bin against the class's *static*
/// `BinGuide` mapping, never against `engineBinID` (judged deposits are always
/// shown residual by design, so that field carries no routing signal).
nonisolated enum PCCPolicyAnalyzer {
    struct Thresholds: Sendable, Equatable {
        let minSamples: Int
        let dominance: Double
    }

    private static var standardThresholds: Thresholds {
        Thresholds(
            minSamples: WasteSortConfig.defaultPCCSuggestionMinSamples,
            dominance: WasteSortConfig.defaultPCCSuggestionDominance
        )
    }

    private static var outOfResidualThresholds: Thresholds {
        Thresholds(
            minSamples: WasteSortConfig.defaultPCCOutOfResidualMinSamples,
            dominance: WasteSortConfig.defaultPCCOutOfResidualDominance
        )
    }

    /// Bins an override may target. Anything else is a taxonomy bug and is
    /// dropped rather than applied.
    private static let overridableBinIDs: Set<String> = [
        BinGuide.organic.id,
        BinGuide.residual.id,
        BinGuide.cleanInorganic.id,
        BinGuide.dirtyRecyclable.id
    ]

    static func suggestions(from records: [PCCVerdictRecord]) -> [SuggestedOverride] {
        var countsByClass: [String: [String: Int]] = [:]
        var displayLabels: [String: String] = [:]

        for record in records {
            guard record.outcome == .answered,
                  !record.mappingFailed,
                  !record.isDiagnostic,
                  let pccBinID = record.pccBinID,
                  !record.yoloLabel.isEmpty
            else { continue }
            let key = BinGuide.normalizedKey(record.yoloLabel)
            countsByClass[key, default: [:]][pccBinID, default: 0] += 1
            if displayLabels[key] == nil { displayLabels[key] = record.yoloLabel }
        }

        var suggestions: [SuggestedOverride] = []
        for (key, binCounts) in countsByClass {
            guard let dominant = singleDominant(in: binCounts),
                  overridableBinIDs.contains(dominant.binID)
            else { continue }

            let total = binCounts.values.reduce(0, +)
            let current = BinGuide.staticInfo(for: key)
            guard dominant.binID != current.id else { continue }

            let direction: SuggestedOverride.Direction
            let thresholds: Thresholds
            if dominant.binID == BinGuide.residual.id {
                direction = .intoResidual
                thresholds = standardThresholds
            } else if current.id == BinGuide.residual.id {
                // Pulling items out of the honest-answer stream is the risky
                // direction (a contaminated recyclable ruins its batch), so it
                // needs a much stronger case (spec FR-2).
                direction = .outOfResidual
                thresholds = outOfResidualThresholds
            } else {
                direction = .lateral
                thresholds = standardThresholds
            }

            // Evidence volume is every answered judgment for the class;
            // dominance measures how unanimous it was.
            guard total >= thresholds.minSamples else { continue }
            let rate = Double(dominant.count) / Double(total)
            guard rate >= thresholds.dominance else { continue }

            suggestions.append(SuggestedOverride(
                id: key,
                itemClass: displayLabels[key] ?? key,
                suggestedBinID: dominant.binID,
                currentStaticBinID: current.id,
                sampleCount: total,
                agreementRate: rate,
                direction: direction
            ))
        }

        return suggestions.sorted {
            $0.sampleCount != $1.sampleCount
                ? $0.sampleCount > $1.sampleCount
                : $0.id < $1.id
        }
    }

    /// Highest count, requiring a strict winner; ties carry no signal.
    private static func singleDominant(
        in binCounts: [String: Int]
    ) -> (binID: String, count: Int)? {
        let ranked = binCounts.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }
        guard let top = ranked.first, ranked.count > 1 else {
            return ranked.first.map { ($0.key, $0.value) }
        }
        return top.value > ranked[1].value ? (top.key, top.value) : nil
    }
}
