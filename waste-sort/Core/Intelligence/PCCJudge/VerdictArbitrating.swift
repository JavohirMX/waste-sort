import CoreGraphics
import Foundation

/// Everything the arbiter needs to know about one qualifying deposit event.
///
/// Built on the inference queue inside `handle()` from immutable snapshots only —
/// no live tracker references cross over with it.
nonisolated struct ArbiterRequestContext: Equatable, Sendable {
    let trackId: Int
    let sessionId: String?
    let yoloLabel: String
    let yoloConfidence: Double
    let beliefUncertain: Bool
    let beliefMargin: Double
    /// The bin verdict actually shown to the visitor — for this feature always
    /// `BinGuide.fallbackBinID`, recorded so the dataset states that explicitly.
    let engineBinID: String
    let pipeline: String
    let triggeredAt: Date
}

/// What the model came back with when everything worked.
nonisolated struct ArbiterAnswer: Equatable, Sendable {
    var rawBinLabel: String
    var material: String?
    var reasoningSummary: String?
    var latencyMs: Int
    var inputTokens: Int?
    var outputTokens: Int?
}

/// Why an arbitration did not produce an answer. Kinds map 1:1 onto record
/// outcomes so every failure stays visible instead of becoming a guess.
nonisolated enum ArbiterError: Error, Equatable, Sendable {
    case timeout
    /// Daily per-user allotment exhausted; not retryable until reset.
    case quotaLimitReached(reset: Date?)
    case unavailable(String)
    case failed(String)
}

/// The seam between trigger logic and whatever asks the cloud model.
/// Production uses a FoundationModels-backed transport on iOS 27+; tests
/// script outcomes here so no hardware or entitlement is ever required.
typealias ArbitrationTransport =
    @Sendable (_ query: ArbiterRequestContext, _ crop: CGImage?) async -> Result<ArbiterAnswer, ArbiterError>

/// Snapshot of every gate the judge consults, for Settings and pre-call checks.
nonisolated struct JudgeStatusSnapshot: Equatable, Sendable {
    var availability: PCCJudgeAvailability
    var approachingLimit: Bool
    var breakerOpenUntil: Date?
    /// When this snapshot was assembled. Snapshots older than the arbiter's
    /// availability TTL are stale — quota state changes during a session.
    var fetchedAt: Date = .distantPast

    var isUsable: Bool {
        guard availability.isReady else { return false }
        if breakerOpenUntil.map({ $0 > Date() }) == true { return false }
        return true
    }
}

nonisolated protocol VerdictArbitrating: Sendable {
    /// Accepts one arbitration request and returns immediately; the answer or
    /// failure lands in the record store asynchronously. Exactly one request per
    /// track id is honored for the service's lifetime.
    func arbitrate(_ context: ArbiterRequestContext, crop: CGImage?)

    /// True once this track has already been submitted (dedupe check).
    func hasRequested(trackId: Int) -> Bool

    func currentStatus() -> JudgeStatusSnapshot

    /// Records a gate rejection (quota, unavailable, disabled…) for a deposit
    /// that would otherwise have qualified, and marks the track served.
    func recordSkip(_ context: ArbiterRequestContext, reasonSkipOutcome outcome: PCCVerdictRecord.Outcome)
}
