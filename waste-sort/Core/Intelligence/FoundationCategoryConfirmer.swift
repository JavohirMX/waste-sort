import CoreGraphics
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Why the confirmation layer can or cannot run right now.
///
/// Three independent things have to line up, and they fail for different reasons, so the
/// settings sheet reports which one is missing rather than a bare "unavailable".
nonisolated enum FoundationCategoryAvailability: Equatable {
    /// The model is there and will answer.
    case ready
    /// The image-prompt API arrived in iOS 27; this device is older.
    case needsNewerOS
    /// iOS 27, but its FoundationModels predates the SDK the app was built against, so the
    /// symbols the image route needs are not exported. See `FoundationModelsABI`.
    case buildMismatch
    /// The API is all there, but the system model itself is not usable.
    case modelUnavailable(String)

    var isReady: Bool { self == .ready }

    var summary: String {
        switch self {
        case .ready:
            return "On-device model ready. \(FoundationModelsABI.imageRouteDetail)"
        case .needsNewerOS:
            return "Needs iOS 27 — the on-device model only accepts images from that release on."
        case .buildMismatch:
            return FoundationModelsABI.imageRouteDetail
        case .modelUnavailable(let reason):
            return "On-device model unavailable: \(reason)"
        }
    }

    static var current: FoundationCategoryAvailability {
        #if canImport(FoundationModels)
        guard #available(iOS 27.0, *) else { return .needsNewerOS }
        guard FoundationModelsABI.supportsStructuredImagePrompt else { return .buildMismatch }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            return .modelUnavailable(describe(reason))
        @unknown default:
            return .modelUnavailable("unrecognized reason")
        }
        #else
        return .needsNewerOS
        #endif
    }

    #if canImport(FoundationModels)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "this device does not support Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            return "turn Apple Intelligence on in Settings"
        case .modelNotReady:
            return "the model is still downloading"
        @unknown default:
            return "unrecognized reason"
        }
    }
    #endif
}

/// Asks the on-device Foundation model which bin one cropped item belongs in.
nonisolated struct FoundationCategoryConfirmer: CategoryConfirming {
    enum Failure: Error {
        /// The image route is not usable on this OS. Callers should not have got here —
        /// `FoundationCategoryAvailability.current` is checked before the layer is enabled.
        case unavailable
    }

    func confirm(image: CGImage) async throws -> ConfirmedCategory? {
        #if canImport(FoundationModels)
        guard #available(iOS 27.0, *), FoundationModelsABI.supportsStructuredImagePrompt else {
            throw Failure.unavailable
        }
        let verdict = try await FoundationImagePrompt.respond(
            instructions: WasteCategoryPrompt.instructions,
            ask: WasteCategoryPrompt.ask,
            imageLabel: WasteCategoryPrompt.imageLabel,
            image: image,
            generating: WasteCategoryVerdict.self,
            maximumResponseTokens: WasteCategoryPrompt.maximumResponseTokens
        )
        return verdict.confirmed(minimumConfidence: WasteCategoryPrompt.minimumConfidence)
        #else
        throw Failure.unavailable
        #endif
    }
}
