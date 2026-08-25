import Foundation

/// Decides whether one deposit event earns a Private Cloud Compute second
/// opinion.
///
/// Pure and synchronous: every input is an immutable snapshot value, so this
/// runs on the inference queue at zero cost when nothing qualifies. The rules
/// are the contract's rule table (specs/001…/contracts/arbitration.md); each
/// rejection names its reason because skipped requests are recorded verbatim.
nonisolated enum PCCTriggerPolicy {
    nonisolated enum SkipReason: Equatable, Sendable {
        case notUncertainFallback
        case confirmationLocked
        case disabled
        case unavailable(String)
        case quotaLimited
        case breakerOpen
        case alreadyRequested
    }

    nonisolated struct Inputs: Sendable {
        /// Deposit resolved through the uncertainty→residual fallback path.
        var wasUncertainFallback: Bool
        /// The confirmation layer has locked a verdict onto this track.
        var confirmationLocked: Bool
        /// Spec 003: audit confident verdicts too. Deliberately ignores
        /// `confirmationLocked` on this path — verifying locked verdicts is
        /// the point. Log-only either way; quota and breaker still gate.
        var confidentAuditEnabled: Bool
        var judgeEnabled: Bool
        var availabilityIsReady: Bool
        var quotaLimited: Bool
        var breakerOpen: Bool
        var alreadyRequested: Bool

        init(
            wasUncertainFallback: Bool,
            confirmationLocked: Bool = false,
            confidentAuditEnabled: Bool = false,
            judgeEnabled: Bool = true,
            availabilityIsReady: Bool = true,
            quotaLimited: Bool = false,
            breakerOpen: Bool = false,
            alreadyRequested: Bool = false
        ) {
            self.wasUncertainFallback = wasUncertainFallback
            self.confirmationLocked = confirmationLocked
            self.confidentAuditEnabled = confidentAuditEnabled
            self.judgeEnabled = judgeEnabled
            self.availabilityIsReady = availabilityIsReady
            self.quotaLimited = quotaLimited
            self.breakerOpen = breakerOpen
            self.alreadyRequested = alreadyRequested
        }
    }

    nonisolated enum Decision: Equatable, Sendable {
        case trigger
        case skip(SkipReason)
    }

    static func decision(for inputs: Inputs) -> Decision {
        guard inputs.judgeEnabled else { return .skip(.disabled) }
        if inputs.wasUncertainFallback {
            // Primary path: a confirmation-locked verdict is settled; the
            // judge never relitigates what the confirmation layer decided.
            guard !inputs.confirmationLocked else { return .skip(.confirmationLocked) }
        } else {
            // Audit path (spec 003): confident verdicts get a silent second
            // opinion when enabled. `confirmationLocked` is intentionally not
            // consulted here.
            guard inputs.confidentAuditEnabled else { return .skip(.notUncertainFallback) }
        }
        guard inputs.availabilityIsReady else {
            return .skip(.unavailable("service not ready"))
        }
        guard !inputs.quotaLimited else { return .skip(.quotaLimited) }
        guard !inputs.breakerOpen else { return .skip(.breakerOpen) }
        guard !inputs.alreadyRequested else { return .skip(.alreadyRequested) }
        return .trigger
    }
}
