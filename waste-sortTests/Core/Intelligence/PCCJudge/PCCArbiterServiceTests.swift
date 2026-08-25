import CoreGraphics
import Foundation
import Testing
@testable import waste_sort

@Suite("PCC arbiter service")
struct PCCArbiterServiceTests {
    private let store: PCCRecordStore
    private var root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcc-arbiter-tests-\(UUID().uuidString)", isDirectory: true)
        store = PCCRecordStore(rootURL: root)
    }

    /// A real 8x8 bitmap so the JPEG pipeline behaves exactly like production.
    private func makeCrop() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) ?? { fatalError("CGContext creation failed") }()
        guard let image = context.makeImage() else { fatalError("makeImage failed") }
        return image
    }

    private func context(trackId: Int = 1) -> ArbiterRequestContext {
        ArbiterRequestContext(
            trackId: trackId,
            sessionId: "session",
            yoloLabel: "chip bag",
            yoloConfidence: 0.42,
            beliefUncertain: true,
            beliefMargin: 0.03,
            engineBinID: BinGuide.fallbackBinID,
            pipeline: "belief",
            triggeredAt: Date()
        )
    }

    /// Polls until `condition` holds or the timeout lapses; returns whether it held.
    private func waitUntil(timeout: Double = 3, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    private func allRecords() -> [PCCVerdictRecord] {
        store.records(in: DateInterval(start: .distantPast, duration: .greatestFiniteMagnitude))
    }

    private func answeredTransport(label: String) -> ArbitrationTransport {
        { _, _ in
            .success(ArbiterAnswer(
                rawBinLabel: label,
                material: "foil laminate",
                reasoningSummary: "multi-layer film is residual",
                latencyMs: 120,
                inputTokens: 10,
                outputTokens: 20
            ))
        }
    }

    @Test("Answered transport produces an answered record with mapped bin and agreement")
    func confidentAuditRecordDisagreement() async throws {
        // Spec 003: a confident deposit audited in the background records
        // agreement against the ADVISED bin (deposit.classKey), not the raw
        // YOLO label's static routing.
        let context = ArbiterRequestContext(
            trackId: 777,
            sessionId: "live",
            yoloLabel: "tissue",
            yoloConfidence: 0.9,
            beliefUncertain: false,
            beliefMargin: 0.4,
            engineBinID: BinGuide.residual.id,
            pipeline: "belief",
            triggeredAt: Date()
        )
        let service = PCCArbiterService(
            store: store,
            transport: answeredTransport(label: "clean_inorganic"),
            availabilityOverride: .ready
        )
        service.arbitrate(context, crop: makeCrop())
        let settled = await waitUntil { self.allRecords().count == 1 }
        #expect(settled, "arbiter never recorded an answer")
        let record = try #require(allRecords().first)
        #expect(record.beliefUncertain == false)
        #expect(record.pccBinID == BinGuide.cleanInorganic.id)
        #expect(record.agreesWithEngine == false)
    }

    func answeredRecord() async throws {
        let service = PCCArbiterService(
            store: store,
            transport: answeredTransport(label: "clean_inorganic"),
            availabilityOverride: .ready
        )
        service.arbitrate(context(), crop: makeCrop())
        let settled = await waitUntil { self.allRecords().count == 1 }
        #expect(settled, "arbiter never recorded an answer")
        let record = try #require(allRecords().first)
        var isAnswered = false
        if case .answered = record.outcome { isAnswered = true }
        #expect(isAnswered, "expected answered, got \(record.outcome)")
        #expect(record.pccRawBinLabel == "clean_inorganic")
        #expect(!record.mappingFailed)
        let mappedID = BinGuide.info(for: "clean_inorganic").id
        #expect(record.agreesWithEngine == (mappedID == BinGuide.fallbackBinID))
        let cropName = record.cropFile
        #expect(cropName?.hasPrefix("crops/") == true)
    }

    @Test("Consecutive failures trip the breaker; open breaker records skips")
    func breakerTrips() async throws {
        var calls = 0
        let failing: ArbitrationTransport = { _, _ in
            calls += 1
            return .failure(.failed("boom"))
        }
        let service = PCCArbiterService(store: store, transport: failing, availabilityOverride: .ready)
        for id in 1...WasteSortConfig.defaultPCCBreakerThreshold {
            service.arbitrate(context(trackId: id), crop: self.makeCrop())
        }
        let failedEnough = await waitUntil {
            self.allRecords().count == WasteSortConfig.defaultPCCBreakerThreshold
        }
        #expect(failedEnough)
        let status = service.currentStatus()
        #expect(status.breakerOpenUntil != nil)

        let callsBefore = calls
        service.arbitrate(context(trackId: 99), crop: makeCrop())
        let skipped = await waitUntil {
            self.allRecords().count == WasteSortConfig.defaultPCCBreakerThreshold + 1
        }
        #expect(skipped)
        #expect(calls == callsBefore, "breaker must gate the transport")
    }

    @Test("Quota-limited availability records skippedQuota without calling the transport")
    func quotaSkip() async throws {
        var called = false
        let probing: ArbitrationTransport = { _, _ in
            called = true
            return .success(ArbiterAnswer(rawBinLabel: "residual", latencyMs: 1))
        }
        let service = PCCArbiterService(
            store: store,
            transport: probing,
            availabilityOverride: .quotaLimited(reset: Date())
        )
        service.arbitrate(context(), crop: makeCrop())
        let settled = await waitUntil { self.allRecords().count == 1 }
        #expect(settled)
        #expect(!called)
        #expect(allRecords().first?.outcome == .skippedQuota)
    }

    @Test("Dedupe: second arbitrate for the same track is ignored entirely")
    func dedupe() async throws {
        var calls = 0
        let counting: ArbitrationTransport = { _, _ in
            calls += 1
            return .success(ArbiterAnswer(rawBinLabel: "residual", latencyMs: 1))
        }
        let service = PCCArbiterService(store: store, transport: counting, availabilityOverride: .ready)
        service.arbitrate(context(trackId: 7), crop: makeCrop())
        service.arbitrate(context(trackId: 7), crop: makeCrop())
        let settled = await waitUntil { self.allRecords().count == 1 && calls == 1 }
        #expect(settled)
        #expect(service.hasRequested(trackId: 7))
        #expect(calls == 1)
    }

    @Test("recordSkip marks the track served so later frames cannot re-fire it")
    func skipMarksServed() async throws {
        let inert: ArbitrationTransport = { _, _ in
            .failure(.failed("should never run"))
        }
        let service = PCCArbiterService(store: store, transport: inert, availabilityOverride: .ready)
        service.recordSkip(context(trackId: 5), reasonSkipOutcome: .skippedDisabled)
        let settled = await waitUntil { self.allRecords().count == 1 }
        #expect(settled)
        #expect(service.hasRequested(trackId: 5))
        service.arbitrate(context(trackId: 5), crop: nil)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(allRecords().count == 1)
    }

    @Test("Missing crop yields a cropFailed record and never reaches the transport")
    func cropFailed() async throws {
        var called = false
        let probing: ArbitrationTransport = { _, _ in
            called = true
            return .success(ArbiterAnswer(rawBinLabel: "residual", latencyMs: 1))
        }
        let service = PCCArbiterService(store: store, transport: probing, availabilityOverride: .ready)
        service.arbitrate(context(), crop: nil)
        let settled = await waitUntil { self.allRecords().count == 1 }
        #expect(settled)
        #expect(!called)
        #expect(allRecords().first?.outcome == .cropFailed)
    }

    @Test("No outcome other than answered ever carries pcc fields (invariant I2)")
    func failuresCarryNoAnswers() async throws {
        let exploding: ArbitrationTransport = { _, _ in
            .failure(.failed("detonated"))
        }
        let service = PCCArbiterService(
            store: store,
            transport: exploding,
            availabilityOverride: .ready
        )
        service.arbitrate(context(), crop: makeCrop())
        let settled = await waitUntil { self.allRecords().count == 1 }
        #expect(settled)
        let record = try #require(allRecords().first)
        #expect(record.pccBinID == nil)
        #expect(record.pccRawBinLabel == nil)
        #expect(record.agreesWithEngine == nil)
        var isError = false
        if case .error = record.outcome { isError = true }
        #expect(isError, "expected error outcome, got \(record.outcome)")
    }

    // MARK: - Smoke path (awaitable diagnostic judgment)

    @Test("smokeJudge returns the answer and records it through the real pipeline")
    func smokeJudgeAnswers() async throws {
        let service = PCCArbiterService(
            store: store,
            transport: answeredTransport(label: "residual"),
            availabilityOverride: .ready
        )
        let judgment = await service.smokeJudge(context(), crop: makeCrop())

        #expect(judgment.answered)
        let answer = try #require(judgment.answer)
        #expect(answer.rawBinLabel == "residual")
        #expect(judgment.record.outcome == .answered)
        #expect(judgment.record.pccBinID == BinGuide.residual.id)
        let settled = await waitUntil { self.allRecords().count == 1 }
        #expect(settled, "smoke judgment was not recorded")
    }

    @Test("smokeJudge surfaces gate outcomes instead of answers")
    func smokeJudgeGateOutcomes() async throws {
        var calls = 0
        let counting: ArbitrationTransport = { _, _ in
            calls += 1
            return .success(ArbiterAnswer(rawBinLabel: "organic", latencyMs: 1))
        }
        let service = PCCArbiterService(
            store: store,
            transport: counting,
            availabilityOverride: .quotaLimited(reset: Date().addingTimeInterval(600))
        )
        let judgment = await service.smokeJudge(context(), crop: makeCrop())

        #expect(!judgment.answered)
        #expect(judgment.answer == nil)
        #expect(judgment.record.outcome == .skippedQuota)
        #expect(calls == 0, "quota gate must run before the transport")
        let settled = await waitUntil { self.allRecords().count == 1 }
        #expect(settled)
    }

    @Test("smokeJudge reports transport failures honestly")
    func smokeJudgeFailure() async throws {
        let exploding: ArbitrationTransport = { _, _ in .failure(.failed("detonated")) }
        let service = PCCArbiterService(
            store: store,
            transport: exploding,
            availabilityOverride: .ready
        )
        let judgment = await service.smokeJudge(context(), crop: makeCrop())

        #expect(!judgment.answered)
        #expect(judgment.answer == nil)
        var isError = false
        if case .error = judgment.record.outcome { isError = true }
        #expect(isError, "expected error outcome, got \(judgment.record.outcome)")
    }
}
