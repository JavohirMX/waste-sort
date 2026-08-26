import CoreGraphics
import Foundation
import Testing
@testable import waste_sort

/// `.serialized` because every test drives a live worker task against a
/// wall-clock budget; six spinning queues distort each other's timings.
@Suite("PCC judge queue", .serialized)
struct PCCJudgeQueueTests {
    private let store: PCCRecordStore

    init() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcc-queue-tests-\(UUID().uuidString)", isDirectory: true)
        store = PCCRecordStore(rootURL: root)
    }

    // MARK: Helpers

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

    private func context(trackId: Int, uncertain: Bool) -> ArbiterRequestContext {
        ArbiterRequestContext(
            trackId: trackId,
            sessionId: "queue-test",
            yoloLabel: "chip bag",
            yoloConfidence: 0.42,
            beliefUncertain: uncertain,
            beliefMargin: uncertain ? 0.03 : 0.4,
            engineBinID: BinGuide.fallbackBinID,
            pipeline: "belief",
            triggeredAt: Date()
        )
    }

    private func allRecords() -> [PCCVerdictRecord] {
        store.records(in: DateInterval(start: .distantPast, duration: .greatestFiniteMagnitude))
    }

    private func waitUntil(timeout: Double = 5, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    /// Builds a queue around a REAL arbiter with a scripted transport, so the
    /// exercised pipeline is exactly what production runs.
    private func makeQueue(
        transport: @escaping ArbitrationTransport,
        availability: PCCJudgeAvailability? = nil,
        dynamicAvailability: (@Sendable () -> PCCJudgeAvailability)? = nil,
        capacity: Int = WasteSortConfig.defaultPCCQueueCapacity,
        entryTTL: TimeInterval = WasteSortConfig.defaultPCCQueueEntryTTLSeconds
    ) -> PCCJudgeQueue {
        let arbiter = PCCArbiterService(
            store: store,
            transport: transport,
            availabilityOverride: availability,
            dynamicAvailability: dynamicAvailability
        )
        return PCCJudgeQueue(
            arbiter: arbiter,
            capacity: capacity,
            entryTTL: entryTTL,
            idlePollInterval: 0.05,
            retryPollInterval: 0.05,
            unknownResetRetryInterval: 0.2
        )
    }

    private func answeredTransport(
        order: OrderRecorder
    ) -> ArbitrationTransport {
        { context, _ in
            order.append(context.trackId)
            return .success(ArbiterAnswer(
                rawBinLabel: "residual",
                material: nil,
                reasoningSummary: nil,
                latencyMs: 1,
                inputTokens: nil,
                outputTokens: nil
            ))
        }
    }

    private final class OrderRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [Int] = []
        func append(_ id: Int) {
            lock.lock()
            ids.append(id)
            lock.unlock()
        }
        func snapshot() -> [Int] {
            lock.lock()
            defer { lock.unlock() }
            return ids
        }
    }

    // MARK: Tests

    /// Scripted availability that tests flip mid-flight. The arbiter calls the
    /// closure fresh on every status check (no caching), so changes land fast.
    private final class ProbeState: @unchecked Sendable {
        var availability: PCCJudgeAvailability = .quotaLimited(reset: .distantFuture)
    }

    @Test("uncertain primaries drain before confident audits, FIFO inside a tier")
    func priorityOrder() async throws {
        let probe = ProbeState()
        let order = OrderRecorder()
        let queue = makeQueue(
            transport: answeredTransport(order: order),
            dynamicAvailability: { probe.availability }
        )

        // Held while enqueuing so the worker cannot pop anything early.
        queue.enqueue(context(trackId: 1, uncertain: false), crop: makeCrop())
        queue.enqueue(context(trackId: 2, uncertain: true), crop: makeCrop())
        queue.enqueue(context(trackId: 3, uncertain: true), crop: makeCrop())
        #expect(queue.depth == 3)

        probe.availability = .ready
        let held = await waitUntil { order.snapshot() == [2, 3, 1] }
        #expect(held, "expected execution order [2, 3, 1], got \(order.snapshot()); state \(queue.debugState)")
    }

    @Test("quota exhaustion holds entries and drains them once reset passes")
    func quotaHoldThenDrain() async throws {
        let order = OrderRecorder()
        // Availability flips from quota-limited to ready mid-test, scripted —
        // no dependence on cache expiry or live system state.
        final class Probe: @unchecked Sendable {
            var availability: PCCJudgeAvailability = .quotaLimited(reset: Date.distantFuture)
        }
        let probe = Probe()
        let queue = makeQueue(
            transport: answeredTransport(order: order),
            dynamicAvailability: { probe.availability }
        )
        let holdCheck = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            return self.allRecords()
        }

        queue.enqueue(context(trackId: 9, uncertain: true), crop: makeCrop())
        #expect(await holdCheck.value.isEmpty, "quota-held entry must not be judged or skipped before reset")

        probe.availability = .ready
        let drained = await waitUntil(timeout: 8) { !self.allRecords().isEmpty }
        #expect(drained, "entry should be judged after quota reset")
        #expect(order.snapshot() == [9])
    }

    @Test("permanent unavailability flushes every held entry as recorded skips")
    func permanentUnavailableFlushesAsSkips() async throws {
        let order = OrderRecorder()
        let queue = makeQueue(
            transport: answeredTransport(order: order),
            availability: .needsNewerOS
        )

        queue.enqueue(context(trackId: 1, uncertain: true), crop: makeCrop())
        queue.enqueue(context(trackId: 2, uncertain: false), crop: makeCrop())

        let flushed = await waitUntil {
            self.allRecords().count == 2
                && self.allRecords().allSatisfy { $0.outcome.isSkippedUnavailable }
        }
        #expect(flushed)
        #expect(order.snapshot().isEmpty, "nothing may reach the transport")
        #expect(queue.depth == 0)
    }

    @Test("ambiguous unavailability holds fresh entries but expires stale ones as skips")
    func ambiguousUnavailableExpiresStaleEntries() async throws {
        let order = OrderRecorder()
        let queue = makeQueue(
            transport: answeredTransport(order: order),
            availability: .modelUnavailable("the system is not ready"),
            entryTTL: 0.15
        )

        queue.enqueue(context(trackId: 5, uncertain: true), crop: makeCrop())

        let expired = await waitUntil {
            self.allRecords().count == 1
                && self.allRecords().first?.outcome.isSkippedUnavailable == true
        }
        #expect(expired, "stale entry should be recorded as skipped")
        #expect(order.snapshot().isEmpty)
        #expect(queue.depth == 0)
    }

    @Test("overflow sheds the oldest audit first and records it as a gate skip")
    func overflowShedsOldestAuditFirst() async throws {
        // Held while enqueuing: capacity 3 fills completely, and admitting the
        // fourth entry must shed the OLDEST CONFIDENT AUDIT (track 11), never
        // an uncertain primary.
        let probe = ProbeState()
        let order = OrderRecorder()
        let queue = makeQueue(
            transport: answeredTransport(order: order),
            dynamicAvailability: { probe.availability },
            capacity: 3
        )

        queue.enqueue(context(trackId: 10, uncertain: true), crop: makeCrop())
        queue.enqueue(context(trackId: 11, uncertain: false), crop: makeCrop())
        queue.enqueue(context(trackId: 12, uncertain: false), crop: makeCrop())

        queue.enqueue(context(trackId: 13, uncertain: true), crop: makeCrop())

        let shedRecorded = await waitUntil {
            let records = self.allRecords()
            return records.count == 1 && !records[0].outcome.isAnswered
        }
        #expect(shedRecorded, "the shed entry should be recorded as a gate skip")
        let shedTrackIDs = Set(allRecords().map(\.trackId))
        #expect(shedTrackIDs == [11], "oldest confident audit should be shed first, got \(shedTrackIDs)")
        #expect(queue.depth == 3)

        probe.availability = .ready
        let judged = await waitUntil { order.snapshot().count == 3 }
        #expect(judged)
        #expect(order.snapshot() == [10, 13, 12], "uncertain primaries first, then remaining audit FIFO")
    }

    @Test("a track id already queued or judged is never enqueued twice")
    func dedupeByTrackID() async throws {
        let probe = ProbeState()
        let order = OrderRecorder()
        let queue = makeQueue(
            transport: answeredTransport(order: order),
            dynamicAvailability: { probe.availability }
        )

        queue.enqueue(context(trackId: 42, uncertain: true), crop: makeCrop())
        queue.enqueue(context(trackId: 42, uncertain: true), crop: makeCrop())
        #expect(queue.depth == 1, "the duplicate must be ignored")

        probe.availability = .ready
        let judged = await waitUntil { order.snapshot() == [42] }
        #expect(judged)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(order.snapshot() == [42])
    }
}

private extension PCCVerdictRecord.Outcome {
    var isSkippedUnavailable: Bool {
        if case .skippedUnavailable = self { return true }
        return false
    }

    var isAnswered: Bool { self == .answered }
}
