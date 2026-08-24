import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)

/// The bins the model is allowed to answer with, plus an explicit way out.
///
/// `unclear` earns its place: without it a language model asked to pick one of three will
/// always pick one, and a coin flip that gets locked in is worse than no answer at all.
/// `dirtyRecyclable` is for recyclable material that may still be dirty — moderate
/// suspicion is enough, not certainty.
@available(iOS 27.0, *)
@Generable
enum WasteBinAnswer: String {
    case organic
    case residual
    case recyclable
    case dirtyRecyclable
    case unclear
}

@available(iOS 27.0, *)
@Generable
struct WasteCategoryVerdict {
    @Guide(
        description: """
        Which bin this item belongs in. Use dirtyRecyclable when the item is recyclable \
        material and leftover food, drink, sauce, or oil looks possible — even if you are \
        only about 40–50% sure. If dirt is a toss-up, pick dirtyRecyclable. Answer unclear \
        if you cannot tell what the item is.
        """
    )
    let bin: WasteBinAnswer

    @Guide(description: "How sure you are, from 0.0 to 1.0.")
    let confidence: Double

    @Guide(description: "What the item is, in two or three words.")
    let item: String
}

@available(iOS 27.0, *)
extension WasteCategoryVerdict {
    /// Straight translation of what the model said. Whether it is good enough to act on is
    /// decided upstream, so a hedged answer still reaches the debug log intact.
    var reading: CategoryReading {
        CategoryReading(
            binID: bin.binID,
            label: item.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: min(max(confidence, 0), 1)
        )
    }
}

@available(iOS 27.0, *)
extension WasteBinAnswer {
    /// The matching `BinGuide` id, or nil when the model declined to choose.
    var binID: String? {
        switch self {
        case .organic:
            return BinGuide.organic.id
        case .residual:
            return BinGuide.residual.id
        case .recyclable:
            return BinGuide.cleanInorganic.id
        case .dirtyRecyclable:
            return BinGuide.dirtyRecyclable.id
        case .unclear:
            return nil
        }
    }
}

#endif

/// Wording handed to the model. Built from `BinGuide` so the bins the model is told about
/// stay the bins the app actually sorts into.
nonisolated enum WasteCategoryPrompt {
    static var instructions: String {
        """
        You are a waste-sorting assistant at a recycling station in Bali (source-separation: \
        organik, anorganik daur ulang, residu). You are shown a close-up photograph of a \
        single item somebody is about to throw away, and you name the bin it belongs in.

        The physical bins are:
        - organic: \(BinGuide.organic.instructions)
        - residual: \(BinGuide.residual.instructions)
        - recyclable: \(BinGuide.cleanInorganic.instructions)

        dirtyRecyclable is not a fourth bin. \(BinGuide.dirtyRecyclable.instructions)
        If the item is recyclable material and dirt looks unlikely, answer recyclable.
        If the item is not recyclable material, answer organic or residual as usual.
        If the photograph is too poor to tell what the item is, answer unclear.

        Judge the item itself, not the hand or the background. If the photograph is blurred \
        or the item is hidden, answer unclear rather than guessing — a wrong answer is worse \
        than no answer, because it gets recorded. Between recyclable and dirtyRecyclable, \
        prefer dirtyRecyclable whenever leftover food, drink, sauce, or oil looks possible.
        """
    }

    static let ask = "Which bin does this item belong in?"

    static let imageLabel = "item_photo"

    /// Enough for the small structured answer, and no more — the response is three fields.
    static let maximumResponseTokens = 96
}
