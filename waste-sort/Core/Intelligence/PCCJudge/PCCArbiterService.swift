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

    // MARK: - Smoke path (photo diagnostic)

    /// The outcome of one awaitable judgment, for surfaces that display the
    /// verdict directly (the photo smoke screen). The record is exactly what
    /// landed in the store.
    nonisolated struct SmokeJudgment: Sendable {
        let record: PCCVerdictRecord
        let answer: ArbiterAnswer?
        let availabilitySummary: String

        var answered: Bool {
            record.outcome == .answered
        }
    }

    /// Runs the full production pipeline — availability gates, timeout race,
    /// breaker, store recording — but awaits and returns the result instead of
    /// detaching. Diagnostic surfaces use this so the smoke test exercises the
    /// same stack the kiosk depends on. Caller supplies a unique trackId.
    func smokeJudge(_ context: ArbiterRequestContext, crop: CGImage?) async -> SmokeJudgment {
        stateLock.lock()
        requestedTrackIDs.insert(context.trackId)
        let status = currentStatusLocked()
        stateLock.unlock()

        let record = await judge(context: context, crop: crop, statusAtTrigger: status)
        return SmokeJudgment(
            record: record.record,
            answer: record.answer,
            availabilitySummary: status.availability.summary
        )
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
        _ = await judge(context: context, crop: crop, statusAtTrigger: statusAtTrigger)
    }

    /// The shared pipeline core. Gates, races the transport, notes breaker
    /// state, records to the store, and returns exactly what was recorded.
    private func judge(
        context: ArbiterRequestContext,
        crop: CGImage?,
        statusAtTrigger: JudgeStatusSnapshot
    ) async -> (record: PCCVerdictRecord, answer: ArbiterAnswer?) {
        // Crop failure is a record, not a silent drop (FR-4).
        guard let crop else {
            let record = failureRecord(for: context, outcome: .cropFailed)
            store.append(record, cropJPEG: nil)
            return (record, nil)
        }

        switch statusAtTrigger.availability {
        case .ready:
            break
        case .quotaLimited(let reset):
            let record = failureRecord(for: context, outcome: .skippedQuota, reset: reset)
            store.append(record, cropJPEG: nil)
            return (record, nil)
        case .needsNewerOS, .buildMismatch:
            let record = failureRecord(for: context, outcome: .skippedUnavailable("iOS too old for PCC"))
            store.append(record, cropJPEG: nil)
            return (record, nil)
        case .modelUnavailable(let reason):
            let record = failureRecord(for: context, outcome: .skippedUnavailable(reason))
            store.append(record, cropJPEG: nil)
            return (record, nil)
        }

        let startedAt = now()
        let transport = self.transport
        let result = await raceWithTimeout(
            timeout: WasteSortConfig.defaultPCCTimeoutSeconds
        ) {
            await transport(context, crop)
        }
        let jpeg = jpegData(crop)

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
        let answer: ArbiterAnswer?
        switch result {
        case .success(let success):
            answer = success
            record = PCCVerdictRecord.answered(
                from: context,
                answer: success,
                cropFile: jpeg != nil ? "" : nil,
                quotaState: quotaState
            )
        case .failure(.timeout):
            answer = nil
            record = failureRecord(for: context, outcome: .timeout)
        case .failure(.quotaLimitReached(let reset)):
            answer = nil
            record = failureRecord(for: context, outcome: .skippedQuota, reset: reset)
        case .failure(.unavailable(let reason)):
            answer = nil
            record = failureRecord(for: context, outcome: .skippedUnavailable(reason))
        case .failure(.failed(let message)):
            answer = nil
            record = failureRecord(for: context, outcome: .error(message))
        }
        store.append(record, cropJPEG: record.outcome == .answered ? jpeg : nil)
        Self.log.info("PCC judge finished track \(context.trackId) → \(String(describing: record.outcome))")
        return (record, answer)
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

/// Sentinel label for text-only PCC probes. Kept outside the iOS-27 gate so
/// diagnostic surfaces (which run on any OS) can reference it.
nonisolated enum PCCTextProbe {
    static let label = "text_probe"
}

#if canImport(FoundationModels)
import UIKit

/// Builds the real FoundationModels transport. Isolated here so the rest of
/// the service stays unit-testable without touching iOS-27-only symbols.
///
/// Call-pattern notes from the first on-device smoke run (iPhone, iOS 27
/// beta): `respond(generating:)` — guided generation — combined with a raw
/// `CGImage` attachment trapped inside the framework (EXC_BAD_ACCESS) even
/// with the entitlement present in binary and profile. The transport now uses
/// the most conservative proven pattern instead: a plain-text `respond`, a
/// strict one-line output contract parsed in-app (unparseable output is an
/// honest error, never a guess), and the image normalized to an 8-bit sRGB
/// JPEG file handed over via `Attachment(imageURL:)` — the same shape the
/// validated `fm` CLI benchmark used.
@available(iOS 27.0, *)
nonisolated enum PCCTransportFactory {
    private static let instructions = """
        You are a waste-sorting judge for a kiosk in Bali, Indonesia under
        Provincial Regulation Pergub 47/2019 and 97/2018. Examine the item image
        carefully. Decide which single stream it belongs in: organic, residual,
        clean_inorganic (clean recyclables such as dry plastic, metal, glass,
        paper), or dirty_recyclable (recyclable items possibly contaminated by
        food, drink, sauce, or oil — rinse then recycle, otherwise residual).
        When unsure even after careful examination, choose residual.
        Reply with EXACTLY one line and nothing else, in this format:
        bin=<organic|residual|clean_inorganic|dirty_recyclable>; material=<primary material, short>; rationale=<one short sentence>
        """

    /// Sentinel `yoloLabel` that makes the transport send a text-only probe
    /// (no attachment). The one non-crashing way to prove PCC connectivity,
    /// quota, and entitlement channel while the vision path is under diagnosis.
    /// Declared outside the iOS-27 gate so diagnostic surfaces can reference it.
    static let textProbeLabel = PCCTextProbe.label

    static func defaultTransport() -> ArbitrationTransport {
        { query, crop in
            let isTextProbe = query.yoloLabel == textProbeLabel
            var imageURL: URL?
            if !isTextProbe {
                guard let crop else { return .failure(.failed("no crop available")) }
                do {
                    imageURL = try normalizedJPEGURL(crop)
                } catch {
                    return .failure(.failed("image normalization failed: \(error.localizedDescription)"))
                }
            }
            if let imageURL {
                defer { try? FileManager.default.removeItem(at: imageURL) }
            }
            do {
                let model = PrivateCloudComputeLanguageModel()
                // Vision preflight: the SDK exposes capability flags precisely
                // so callers do not send unsupported content. A beta runtime
                // that lacks vision may trap on attachments instead of
                // throwing `unsupportedCapability` — never hand it an image
                // it did not declare support for.
                if !isTextProbe, !model.capabilities.contains(.vision) {
                    return .failure(.unavailable(
                        "this PCC runtime does not declare vision support (capabilities: \(describe(model.capabilities)))"
                    ))
                }
                // Session + respond form mirrored from the validated
                // text-based PCC app on this device: `LanguageModelSession(
                // model:)` with no instructions parameter. The prompt builder
                // is required to carry an Attachment; the text probe uses the
                // same builder WITHOUT one, so on-device results bisect
                // cleanly: probe OK + image trap = the Attachment path itself.
                let session = LanguageModelSession(model: model)
                let started = CFAbsoluteTimeGetCurrent()
                let response = try await session.respond {
                    if isTextProbe {
                        "Connectivity probe. Reply with exactly: OK"
                    } else {
                        """
                        \(instructions)
                        Judge the item in the attached image. On-device label hint: \(query.yoloLabel) (may be unavailable).
                        """
                        if let imageURL {
                            Attachment(imageURL: imageURL).label("cropped item")
                        }
                    }
                }
                let latencyMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
                let text = response.content
                if isTextProbe {
                    return .success(ArbiterAnswer(
                        rawBinLabel: text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64).description,
                        material: "connectivity probe",
                        reasoningSummary: "text-only PCC probe succeeded",
                        latencyMs: latencyMs
                    ))
                }
                guard let parsed = parseVerdict(text) else {
                    return .failure(.failed("unparseable PCC response: \(String(text.prefix(160)))"))
                }
                return .success(ArbiterAnswer(
                    rawBinLabel: parsed.bin,
                    material: parsed.material,
                    reasoningSummary: parsed.rationale,
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

    /// Human-readable capability set for diagnostics surfaces.
    static func capabilitiesSummary() -> String? {
        guard #available(iOS 27.0, *) else { return nil }
        let capabilities = PrivateCloudComputeLanguageModel().capabilities
        return describe(capabilities)
    }

    private static func describe(_ capabilities: LanguageModelCapabilities) -> String {
        let all: [(LanguageModelCapabilities.Capability, String)] = [
            (.vision, "vision"),
            (.guidedGeneration, "guidedGeneration"),
            (.reasoning, "reasoning"),
            (.toolCalling, "toolCalling"),
        ]
        let supported = all.filter { capabilities.contains($0.0) }.map(\.1)
        return supported.isEmpty ? "none" : supported.joined(separator: ", ")
    }

    /// Redraws any bitmap into a plain 8-bit sRGB JPEG on disk. Gallery-derived
    /// CGImages can be 10-bit, Display-P3, or float; the framework's attachment
    /// path is at its most proven with exactly what the validated benchmark fed it.
    private static func normalizedJPEGURL(_ image: CGImage) throws -> URL {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PCCImageNormalizationError.contextFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let normalized = context.makeImage() else {
            throw PCCImageNormalizationError.makeImageFailed
        }
        guard let jpeg = UIImage(cgImage: normalized).jpegData(compressionQuality: 0.85) else {
            throw PCCImageNormalizationError.jpegFailed
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcc-judge-\(UUID().uuidString).jpg")
        try jpeg.write(to: url, options: .atomic)
        return url
    }

    /// Strict parser for the one-line output contract. Longest/most-specific
    /// bin tokens are matched before "organic" so "clean_inorganic" can never
    /// degrade into "organic". No match = failure, never a guess.
    static func parseVerdict(_ text: String) -> (bin: String, material: String?, rationale: String?)? {
        let lowered = text.lowercased().replacingOccurrences(of: "-", with: "_")
        let candidates = ["dirty_recyclable", "clean_inorganic", "residual", "organic"]
        guard let bin = candidates.first(where: { lowered.contains($0) }) else { return nil }
        let material = materialValue(in: lowered, key: "material")
        let rationale = materialValue(in: lowered, key: "rationale")
        return (bin, material, rationale)
    }

    private static func materialValue(in text: String, key: String) -> String? {
        guard let range = text.range(of: "\(key)\\s*=\\s*([^;\\n]+)", options: .regularExpression) else {
            return nil
        }
        let value = text[range].replacingOccurrences(of: "\(key)", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ="))
        return value.isEmpty ? nil : value
    }
}

/// Why image normalization could not produce the JPEG the transport needs.
private enum PCCImageNormalizationError: Error {
    case contextFailed
    case makeImageFailed
    case jpegFailed
}
#endif
