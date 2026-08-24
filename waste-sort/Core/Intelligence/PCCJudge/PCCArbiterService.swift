import CoreGraphics
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import Network
import os

/// The production arbiter: turns qualifying deposits into recorded PCC verdicts.
///
/// Guarantees (contract invariants I1/I2/I6):
/// - one request per track id for the service's lifetime,
/// - every attempt — answer, timeout, error, or skip — becomes a store record,
/// - no FoundationModels throw escapes; there is no code path that invents an
///   answer when the model fails (Constitution III).
///
/// Runs its work on detached tasks so the inference queue only pays the cost of
/// the policy decision. State below is lock-guarded rather than actor-isolated:
/// `arbitrate`/`hasRequested` are called synchronously from `handle()`.
nonisolated final class PCCArbiterService: VerdictArbitrating, @unchecked Sendable {
    private let store: PCCRecordStore
    private let transport: ArbitrationTransport
    private let now: () -> Date
    private let pathMonitor: NWPathMonitor
    private let stateLock = NSLock()

    private var requestedTrackIDs = Set<Int>()
    private var consecutiveFailures = 0
    private var breakerOpenUntil: Date?
    /// Availability probes touch system APIs, so they are throttled rather than
    /// trusted forever — quota state especially changes during a session.
    private var availabilityCache: (value: PCCJudgeAvailability, fetchedAt: Date)?
    private var cachedStatus: JudgeStatusSnapshot?
    private static let availabilityTTL: Double = 30

    private static let log = AppLog.vision

    /// - Parameters:
    ///   - transport: the cloud call. Defaults to the FoundationModels-backed
    ///     transport on iOS 27+; tests inject scripted outcomes here.
    ///   - now: injectable clock for breaker cooldown tests.
    ///   - availabilityOverride: pins the availability probe. Tests use this to
    ///     exercise gates without touching system APIs; production passes nil.
    init(
        store: PCCRecordStore,
        transport: ArbitrationTransport? = nil,
        now: @escaping () -> Date = Date.init,
        availabilityOverride: PCCJudgeAvailability? = nil
    ) {
        self.store = store
        self.now = now
        if let transport {
            self.transport = transport
        } else if #available(iOS 27.0, *) {
            self.transport = PCCTransportFactory.defaultTransport()
        } else {
            self.transport = { _, _ in .failure(.unavailable("iOS too old for Private Cloud Compute")) }
        }
        if let availabilityOverride {
            availabilityCache = (availabilityOverride, now())
        }
        pathMonitor = NWPathMonitor()
        pathMonitor.start(queue: DispatchQueue(label: "sortla.pccjudge.path"))
    }

    deinit { pathMonitor.cancel() }

    // MARK: VerdictArbitrating

    func arbitrate(_ context: ArbiterRequestContext, crop: CGImage?) {
        stateLock.lock()
        guard !requestedTrackIDs.contains(context.trackId) else {
            stateLock.unlock()
            return
        }
        requestedTrackIDs.insert(context.trackId)
        let status = currentStatusLocked()
        stateLock.unlock()

        let decisionContext = context
        Task.detached(priority: .utility) { [weak self] in
            await self?.run(context: decisionContext, crop: crop, statusAtTrigger: status)
        }
    }

    func hasRequested(trackId: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return requestedTrackIDs.contains(trackId)
    }

    /// Persists a gate rejection for an otherwise-qualifying deposit and marks
    /// the track served, so repeated frames cannot spam identical skip rows.
    func recordSkip(_ context: ArbiterRequestContext, reasonSkipOutcome outcome: PCCVerdictRecord.Outcome) {
        stateLock.lock()
        guard !requestedTrackIDs.contains(context.trackId) else {
            stateLock.unlock()
            return
        }
        requestedTrackIDs.insert(context.trackId)
        stateLock.unlock()
        store.append(failureRecord(for: context, outcome: outcome), cropJPEG: nil)
    }

    func currentStatus() -> JudgeStatusSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentStatusLocked()
    }

    // MARK: - Pipeline

    private func currentStatusLocked() -> JudgeStatusSnapshot {
        if let cached = cachedStatus, !(cached.breakerOpenUntil.map { $0 > now() } ?? false) {
            return cached
        }
        let availability: PCCJudgeAvailability
        if let cache = availabilityCache, now().timeIntervalSince(cache.fetchedAt) < Self.availabilityTTL {
            availability = cache.value
        } else {
            availability = PCCJudgeAvailability.current
            availabilityCache = (availability, now())
        }
        let snapshot = JudgeStatusSnapshot(
            availability: availability,
            approachingLimit: false,
            breakerOpenUntil: breakerOpenUntil
        )
        cachedStatus = snapshot
        return snapshot
    }

    private func run(
        context: ArbiterRequestContext,
        crop: CGImage?,
        statusAtTrigger: JudgeStatusSnapshot
    ) async {
        // Crop failure is a record, not a silent drop (FR-4).
        guard let crop else {
            store.append(failureRecord(for: context, outcome: .cropFailed), cropJPEG: nil)
            return
        }

        switch statusAtTrigger.availability {
        case .ready:
            break
        case .quotaLimited(let reset):
            store.append(failureRecord(for: context, outcome: .skippedQuota, reset: reset), cropJPEG: nil)
            return
        case .needsNewerOS, .buildMismatch:
            store.append(
                failureRecord(for: context, outcome: .skippedUnavailable("iOS too old for PCC")),
                cropJPEG: nil
            )
            return
        case .modelUnavailable(let reason):
            store.append(
                failureRecord(for: context, outcome: .skippedUnavailable(reason)),
                cropJPEG: nil
            )
            return
        }

        let startedAt = now()
        let transport = self.transport
        let result = await raceWithTimeout(
            timeout: WasteSortConfig.defaultPCCTimeoutSeconds
        ) {
            await transport(context, crop)
        }
        let jpeg = jpegData(crop)
        finish(context: context, result: result, startedAt: startedAt, cropJPEG: jpeg)
    }

    /// Bounds the transport at exactly `timeout` seconds; the losing branch is
    /// cancelled and the winner's value (or the deadline) is returned.
    private func raceWithTimeout(
        timeout: Double,
        _ operation: @escaping @Sendable () async -> Result<ArbiterAnswer, ArbiterError>
    ) async -> Result<ArbiterAnswer, ArbiterError> {
        await withTaskGroup(of: Result<ArbiterAnswer, ArbiterError>.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .failure(.timeout)
            }
            guard let first = await group.next() else { return .failure(.failed("race produced no result")) }
            group.cancelAll()
            return first
        }
    }

    private func finish(
        context: ArbiterRequestContext,
        result: Result<ArbiterAnswer, ArbiterError>,
        startedAt: Date,
        cropJPEG: Data?
    ) {
        stateLock.lock()
        switch result {
        case .success:
            consecutiveFailures = 0
        case .failure(let error):
            noteFailureLocked(error)
        }
        let quotaState = quotaLabel(from: result)
        stateLock.unlock()

        let record: PCCVerdictRecord
        switch result {
        case .success(let answer):
            record = PCCVerdictRecord.answered(
                from: context,
                answer: answer,
                cropFile: cropJPEG != nil ? "" : nil,
                quotaState: quotaState
            )
        case .failure(.timeout):
            record = failureRecord(for: context, outcome: .timeout)
        case .failure(.quotaLimitReached(let reset)):
            record = failureRecord(for: context, outcome: .skippedQuota, reset: reset)
        case .failure(.unavailable(let reason)):
            record = failureRecord(for: context, outcome: .skippedUnavailable(reason))
        case .failure(.failed(let message)):
            record = failureRecord(for: context, outcome: .error(message))
        }
        store.append(record, cropJPEG: record.outcome == .answered ? cropJPEG : nil)
        Self.log.info("PCC judge finished track \(context.trackId) → \(String(describing: record.outcome))")
    }

    private func noteFailureLocked(_ error: ArbiterError) {
        guard isBreakerEligible(error) else { return }
        consecutiveFailures += 1
        if consecutiveFailures >= WasteSortConfig.defaultPCCBreakerThreshold {
            breakerOpenUntil = now().addingTimeInterval(WasteSortConfig.defaultPCCBreakerCooldownSeconds)
            consecutiveFailures = 0
            Self.log.warning("PCC judge circuit breaker opened for \(WasteSortConfig.defaultPCCBreakerCooldownSeconds)s")
        }
        cachedStatus = nil
        availabilityCache = nil
    }

    /// Quota exhaustion disables until reset by design; it is not a transient
    /// fault, so it must not trip the breaker (it would just reopen forever).
    private func isBreakerEligible(_ error: ArbiterError) -> Bool {
        switch error {
        case .quotaLimitReached, .unavailable: return false
        default: return true
        }
    }

    private func quotaLabel(from result: Result<ArbiterAnswer, ArbiterError>) -> String? {
        switch result {
        case .failure(.quotaLimitReached): return "limitReached"
        default: return nil
        }
    }

    private func failureRecord(
        for context: ArbiterRequestContext,
        outcome: PCCVerdictRecord.Outcome,
        reset: Date? = nil
    ) -> PCCVerdictRecord {
        PCCVerdictRecord(
            sessionId: context.sessionId,
            trackId: context.trackId,
            cropFile: nil,
            yoloLabel: context.yoloLabel,
            yoloConfidence: context.yoloConfidence,
            beliefUncertain: context.beliefUncertain,
            beliefMargin: context.beliefMargin,
            engineBinID: context.engineBinID,
            pipeline: context.pipeline,
            outcome: outcome
        )
    }

    private func jpegData(_ image: CGImage) -> Data? {
        let bitmap = UIImage(cgImage: image)
        return bitmap.jpegData(compressionQuality: 0.85)
    }
}

#if canImport(FoundationModels)
import UIKit

/// Builds the real FoundationModels transport. Isolated here so the rest of
/// the service stays unit-testable without touching iOS-27-only symbols.
/// Mirrors the session/prompt idioms of `FoundationImagePrompt` exactly.
@available(iOS 27.0, *)
nonisolated enum PCCTransportFactory {
    private static let instructions = """
        You are a waste-sorting judge for a kiosk in Bali, Indonesia under
        Provincial Regulation Pergub 47/2019 and 97/2018. Examine the item image
        carefully. Decide which single stream it belongs in: organic, residual,
        clean_inorganic (clean recyclables such as dry plastic, metal, glass,
        paper), or dirty_recyclable (recyclable items possibly contaminated by
        food, drink, sauce, or oil — rinse then recycle, otherwise residual).
        When unsure even after careful examination, choose residual. Name the
        primary material and give a one-sentence disposal rationale.
        """

    static func defaultTransport() -> ArbitrationTransport {
        { query, crop in
            guard let crop else { return .failure(.failed("no crop available")) }
            do {
                let model = PrivateCloudComputeLanguageModel()
                let session = LanguageModelSession(
                    model: model,
                    instructions: instructions
                )
                let started = CFAbsoluteTimeGetCurrent()
                let response = try await session.respond(
                    generating: PCCBinVerdict.self,
                    options: GenerationOptions(
                        samplingMode: .greedy,
                        maximumResponseTokens: 512
                    )
                ) {
                    "Item seen at deposit time. YOLO label was \(query.yoloLabel), but the kiosk engine was unsure."
                    Attachment(crop).label("cropped item")
                }
                let verdict = response.content
                let latencyMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
                return .success(ArbiterAnswer(
                    rawBinLabel: verdict.bin,
                    material: verdict.material,
                    reasoningSummary: verdict.rationale,
                    latencyMs: latencyMs,
                    inputTokens: response.usage.input.totalTokenCount,
                    outputTokens: response.usage.output.totalTokenCount
                ))
            } catch let error as PrivateCloudComputeLanguageModel.Error {
                switch error {
                case .quotaLimitReached:
                    let reset = PrivateCloudComputeLanguageModel().quotaUsage.resetDate
                    return .failure(.quotaLimitReached(reset: reset))
                @unknown default:
                    return .failure(.failed(String(describing: error)))
                }
            } catch {
                return .failure(.failed(error.localizedDescription))
            }
        }
    }

    /// Structured verdict the model must fill. Kept deliberately small; the bin
    /// label maps through `BinGuide` afterwards, and unknown labels are data.
    @Generable
    nonisolated struct PCCBinVerdict {
        @Guide(description: "One of: organic, residual, clean_inorganic, dirty_recyclable")
        var bin: String
        @Guide(description: "Primary material of the item, e.g. PET plastic, foil laminate")
        var material: String
        @Guide(description: "One sentence disposal rationale")
        var rationale: String
    }
}
#endif
