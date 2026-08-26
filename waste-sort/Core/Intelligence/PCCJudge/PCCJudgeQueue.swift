import CoreGraphics
import Foundation
import os

/// The awaitable seam the queue drains through. Production is the arbiter's
/// full pipeline (`smokeJudge`: gates, timeout race, breaker, store record);
/// tests reuse the real service with a scripted transport.
nonisolated protocol PCCJudgeExecuting: Sendable {
    func execute(_ context: ArbiterRequestContext, crop: CGImage?) async
}

extension PCCArbiterService: PCCJudgeExecuting {
    /// Runs the complete judgment pipeline and records exactly one verdict to
    /// the store. The returned diagnostic snapshot is irrelevant here.
    func execute(_ context: ArbiterRequestContext, crop: CGImage?) async {
        _ = await smokeJudge(context, crop: crop)
    }
}

/// Buffers deposit judgments so back-to-back throws cannot stampede quota.
///
/// Why this exists: the live path used to fire one detached request per
/// deposit, so a busy kiosk spent its daily allotment in a burst and every
/// later judgment was recorded as skipped. The queue turns that into a
/// single-file line with explicit rules about who waits for what:
///
/// - **One request in flight.** Each call costs seconds; serializing them
///   bounds quota spend without any coordination logic.
/// - **Uncertain primaries first**, then FIFO. Spec 001's ordering guarantee
///   survives queuing: quota starvation can only ever reach audits.
/// - **Quota exhaustion holds the line** (operator decision): entries sit
///   until the reported reset time and then drain, instead of dying as skips.
/// - **Breaker cooldown holds too** — it is minutes, not hours.
/// - **Permanent unavailability flushes**: old OS / build mismatch will never
///   recover mid-session, so held crops would be lies. Recorded as skips.
/// - **Ambiguous unavailability retries briefly** (Apple Intelligence warming
///   up, network blip): each entry may outlive `entryTTL` of this state, then
///   it is recorded as skipped rather than judged from stale pixels.
///
/// Enqueue happens synchronously on the inference queue (lock-guarded, like
/// `PCCArbiterService`); all waiting lives in the single worker task.
nonisolated final class PCCJudgeQueue: @unchecked Sendable {
    private struct Entry {
        let context: ArbiterRequestContext
        let crop: CGImage?
        let enqueuedAt: Date
        /// Rank 0 = uncertain primary, 1 = confident audit. Lower drains first.
        let priority: Int
    }

    private let arbiter: VerdictArbitrating & PCCJudgeExecuting
    private let now: () -> Date
    private let capacity: Int
    private let entryTTL: TimeInterval
    private let idlePollInterval: TimeInterval
    private let retryPollInterval: TimeInterval
    private let unknownResetRetryInterval: TimeInterval
    private static let log = AppLog.vision

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var queuedTrackIDs = Set<Int>()
    private var worker: Task<Void, Never>?
    /// Idle polls before the worker retires. A kiosk goes quiet between
    /// visitors; a parked task polling forever is pure waste.
    private let idleRetireCycles: Int

    init(
        arbiter: VerdictArbitrating & PCCJudgeExecuting,
        now: @escaping () -> Date = Date.init,
        capacity: Int = WasteSortConfig.defaultPCCQueueCapacity,
        entryTTL: TimeInterval = WasteSortConfig.defaultPCCQueueEntryTTLSeconds,
        idlePollInterval: TimeInterval = 0.25,
        retryPollInterval: TimeInterval = WasteSortConfig.defaultPCCQueueRetryPollSeconds,
        unknownResetRetryInterval: TimeInterval = WasteSortConfig.defaultPCCQueueQuotaRetrySeconds
    ) {
        self.arbiter = arbiter
        self.now = now
        self.capacity = capacity
        self.entryTTL = entryTTL
        self.idlePollInterval = idlePollInterval
        self.retryPollInterval = retryPollInterval
        self.unknownResetRetryInterval = unknownResetRetryInterval
        // Retire after ~2 s of continuous idleness.
        self.idleRetireCycles = max(1, Int(2.0 / idlePollInterval))
    }

    deinit { worker?.cancel() }

    // MARK: - Inference-queue side

    /// Accepts one qualifying judgment. Synchronous and cheap: eviction of
    /// overflow is the only bookkeeping beyond the append.
    func enqueue(_ context: ArbiterRequestContext, crop: CGImage?) {
        lock.lock()
        defer { lock.unlock() }
        guard !queuedTrackIDs.contains(context.trackId) else { return }
        queuedTrackIDs.insert(context.trackId)

        let entry = Entry(
            context: context,
            crop: crop,
            enqueuedAt: now(),
            priority: context.beliefUncertain ? 0 : 1
        )
        shedOverflowIfNeeded()
        entries.append(entry)
        ensureWorkerLocked()
    }

    /// Overflow sheds the lowest-priority oldest entries first: confident
    /// audits before uncertain primaries, and within a tier, the longest-
    /// waiting. Every shed entry stays honest — recorded as a gate skip.
    private func shedOverflowIfNeeded() {
        while entries.count >= capacity {
            let shedIndex = entries.firstIndex(where: { $0.priority == 1 })
                ?? (entries.isEmpty ? nil : 0)
            guard let shedIndex else { break }
            let shed = entries.remove(at: shedIndex)
            queuedTrackIDs.remove(shed.context.trackId)
            Self.log.info("PCC queue full (\(self.capacity)) — shedding track \(shed.context.trackId)")
            arbiter.recordSkip(shed.context, reasonSkipOutcome: .error("gate: queue-full"))
        }
    }

    /// Diagnostics for settings surfaces.
    var depth: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    #if DEBUG
    /// Test observability: is the worker task alive, and what did it last see?
    struct DebugSnapshot {
        var workerAlive: Bool
        var depth: Int
        var lastStatusSeen: String
    }
    var debugState: DebugSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DebugSnapshot(workerAlive: worker != nil, depth: entries.count, lastStatusSeen: lastStatusSeen)
    }
    private var lastStatusSeen = "none"
    #endif

    // MARK: - Worker side

    /// Starts the drain loop once. Caller holds the lock.
    private func ensureWorkerLocked() {
        guard worker == nil else { return }
        worker = Task.detached(priority: .utility) { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        var idleCycles = 0
        while !Task.isCancelled {
            guard let head = peekNext() else {
                idleCycles = await idleTick(idleCycles)
                continue
            }
            idleCycles = 0
            let status = arbiter.currentStatus()
            #if DEBUG
            lock.lock()
            lastStatusSeen = String(describing: status.availability)
            lock.unlock()
            #endif
            await drain(head, availability: status.availability)
        }
    }

    /// Counts an empty poll and self-retires after a sustained idle stretch:
    /// the next enqueue starts a fresh worker. Retirement happens under the
    /// lock so it can never race an entry that just landed. Returns the count.
    private func idleTick(_ cycles: Int) async -> Int {
        let cycles = cycles + 1
        guard cycles >= idleRetireCycles else {
            await sleep(idlePollInterval)
            return cycles
        }
        lock.lock()
        let retire = entries.isEmpty && worker != nil
        if retire { worker = nil }
        lock.unlock()
        if retire { return cycles }
        await sleep(idlePollInterval)
        return cycles
    }

    /// One pass of the state machine for the current head entry.
    private func drain(_ head: Entry, availability: PCCJudgeAvailability) async {
        switch availability {
        case .ready:
            await executeAndRelease(head)
        case .quotaLimited(let reset):
            // Operator rule: hold everything until the reset lands.
            let wake = reset ?? now().addingTimeInterval(unknownResetRetryInterval)
            await sleep(until: min(wake, now().addingTimeInterval(unknownResetRetryInterval)))
        case .needsNewerOS, .buildMismatch:
            await flushAll(reason: "gate: pcc-unavailable")
        case .modelUnavailable:
            await holdOrExpireStale(head)
        }
    }

    private func executeAndRelease(_ head: Entry) async {
        guard let entry = pop(trackId: head.context.trackId) else { return }
        await arbiter.execute(entry.context, crop: entry.crop)
        lock.lock()
        queuedTrackIDs.remove(entry.context.trackId)
        lock.unlock()
    }

    /// Ambiguous unavailability may clear on its own (system warming, network
    /// returning). Hold fresh entries; retire stale ones honestly.
    private func holdOrExpireStale(_ head: Entry) async {
        if now().timeIntervalSince(head.enqueuedAt) > entryTTL {
            if let entry = pop(trackId: head.context.trackId) {
                arbiter.recordSkip(entry.context, reasonSkipOutcome: .skippedUnavailable("judge queue entry expired"))
            }
        }
        await sleep(retryPollInterval)
    }

    /// Highest priority first: uncertain primaries ahead of confident audits,
    /// FIFO inside each tier.
    private func peekNext() -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries.min { lhs, rhs in
            (lhs.priority, lhs.enqueuedAt) < (rhs.priority, rhs.enqueuedAt)
        }
    }

    private func pop(trackId: Int) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.context.trackId == trackId }) else { return nil }
        return entries.remove(at: index)
    }

    /// Permanent unavailability: nothing held will ever be judged. Record
    /// every entry as the skip it truly was and empty the line.
    private func flushAll(reason: String) async {
        let drained: [ArbiterRequestContext] = lock.withLock {
            let contexts = entries.map(\.context)
            entries.removeAll()
            for context in contexts { queuedTrackIDs.remove(context.trackId) }
            return contexts
        }
        for context in drained {
            arbiter.recordSkip(context, reasonSkipOutcome: .skippedUnavailable(reason))
        }
        await sleep(idlePollInterval)
    }

    private func sleep(_ interval: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
    }

    private func sleep(until date: Date) async {
        await sleep(date.timeIntervalSince(now()))
    }
}
