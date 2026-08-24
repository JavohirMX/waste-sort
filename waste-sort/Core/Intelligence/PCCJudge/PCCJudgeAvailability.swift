import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Why the PCC judge can or cannot run right now.
///
/// Mirrors `FoundationCategoryAvailability`: independent failure reasons are
/// distinct cases so the settings sheet can say what is actually missing.
/// Availability is checked BEFORE any Private Cloud Compute symbol is touched —
/// those APIs arrived in iOS 27 while this app deploys to 26.5, so they bind as
/// weak imports and a build/OS mismatch would trap rather than throw (see
/// `FoundationModelsABI` for the full hazard write-up).
nonisolated enum PCCJudgeAvailability: Equatable {
    /// Entitlement, Apple Intelligence, network, and quota all line up.
    case ready
    /// This OS predates `PrivateCloudComputeLanguageModel`.
    case needsNewerOS
    /// iOS 27, but its FoundationModels build does not export the PCC symbols
    /// the app was compiled against. Calling them would jump to address 0.
    case buildMismatch
    /// The API is present but the service refused: device eligibility, Apple
    /// Intelligence off, entitlement missing, or the system not being ready.
    case modelUnavailable(String)
    /// Serviceable, but today's per-user request allotment is spent.
    case quotaLimited(reset: Date?)

    var isReady: Bool { self == .ready }

    var summary: String {
        switch self {
        case .ready:
            return "Private Cloud Compute ready."
        case .needsNewerOS:
            return "Needs iOS 27 — cloud judgments are unavailable on this OS."
        case .buildMismatch:
            return "This iOS build predates the Private Cloud Compute API. Update iOS to match the Xcode SDK."
        case .modelUnavailable(let reason):
            return "Private Cloud Compute unavailable: \(reason)"
        case .quotaLimited(let reset):
            if let reset {
                return "Daily usage limit reached — resets \(reset.formatted(date: .abbreviated, time: .shortened))."
            }
            return "Daily usage limit reached."
        }
    }

    static var current: PCCJudgeAvailability {
        #if canImport(FoundationModels)
        guard #available(iOS 27.0, *) else { return .needsNewerOS }
        guard PCCJudgeABI.supportsPCCModel else { return .buildMismatch }
        let model = PrivateCloudComputeLanguageModel()
        switch model.availability {
        case .available:
            let usage = model.quotaUsage
            if usage.isLimitReached { return .quotaLimited(reset: usage.resetDate) }
            return .ready
        case .unavailable(.deviceNotEligible):
            return .modelUnavailable("this device does not support Apple Intelligence")
        case .unavailable(.systemNotReady):
            return .modelUnavailable("the system is not ready — check network and Settings")
        case .unavailable(let other):
            return .modelUnavailable(describe(other))
        @unknown default:
            return .modelUnavailable("unrecognized reason")
        }
        #else
        return .needsNewerOS
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 27.0, *)
    private static func describe(_ reason: PrivateCloudComputeLanguageModel.Availability.UnavailableReason) -> String {
        String(describing: reason)
    }
    #endif
}

#if canImport(FoundationModels)
/// Runtime presence checks for the Private Cloud Compute symbols this app calls,
/// which are newer than its deployment target and therefore weak imports.
///
/// A weak import the running OS does not export binds to address 0 and calling it
/// kills the process; `#available` cannot help because the hazard is a *build*
/// mismatch on an otherwise-current OS. The probe resolves each mangled symbol
/// through `dlsym` exactly once and caches the verdict. Regenerate the lists
/// after an SDK change with:
///
///     nm -m <DerivedData>/…/Objects-normal/arm64/*.o \
///       | grep 'weak external' | grep FoundationModels
nonisolated enum PCCJudgeABI {
    static var supportsPCCModel: Bool { allLinked(pccSymbols) }

    /// Every Private Cloud Compute symbol the judge touches, extracted from the
    /// object files after a successful build (see header note). If ANY of these
    /// is missing from the running OS, calling it would jump to address 0 — so
    /// availability reports `.buildMismatch` instead.
    private static let pccSymbols: [String] = [
        "$s16FoundationModels32PrivateCloudComputeLanguageModelCMa",
        "$s16FoundationModels32PrivateCloudComputeLanguageModelCACycfC",
        "$s16FoundationModels32PrivateCloudComputeLanguageModelC12availabilityAC12AvailabilityOvg",
        "$s16FoundationModels32PrivateCloudComputeLanguageModelC10quotaUsageAC05QuotaI0Vvg",
        "$s16FoundationModels32PrivateCloudComputeLanguageModelC10QuotaUsageVMa",
        "$s16FoundationModels32PrivateCloudComputeLanguageModelC10QuotaUsageV14isLimitReachedSbvg",
        "$s16FoundationModels32PrivateCloudComputeLanguageModelC10QuotaUsageV9resetDate0A00K0VSgvg",
        "$s16FoundationModels32PrivateCloudComputeLanguageModelC5ErrorOMa",
        "$s16FoundationModels32PrivateCloudComputeLanguageModelC5ErrorO17QuotaLimitReachedVMa",
        "$s16FoundationModels32PrivateCloudComputeLanguageModelCAA0fG0AAMc"
    ]

    private static func allLinked(_ symbols: [String]) -> Bool {
        guard !symbols.isEmpty else { return true }
        for symbol in symbols {
            guard dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol) != nil else { return false }
        }
        return true
    }
}
#endif
