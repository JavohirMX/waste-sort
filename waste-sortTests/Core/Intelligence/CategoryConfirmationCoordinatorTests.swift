import CoreGraphics
import Foundation
import Testing

@testable import waste_sort

/// Answers whatever the test told it to, and counts how often it was asked.
private nonisolated final class StubConfirmer: CategoryConfirming, @unchecked Sendable {
    struct Boom: Error, Equatable {}

    /// Consumed in order; the last one repeats once the list runs out. A nil entry throws.
    var answers: [CategoryReading?]
    private(set) var calls = 0

    init(answers: [CategoryReading?]) {
        self.answers = answers
    }

    func read(image: CGImage) async throws -> CategoryReading {
        defer { calls += 1 }
        let answer = calls < answers.count ? answers[calls] : answers.last ?? nil
        guard let answer else { throw Boom() }
        return answer
    }
}

@Suite("CategoryConfirmationCoordinator")
struct CategoryConfirmationCoordinatorTests {
    private static let organic = CategoryReading(
        binID: BinGuide.organic.id,
        label: "apple core",
        confidence: 0.9
    )
    private static let recyclable = CategoryReading(
        binID: BinGuide.cleanInorganic.id,
        label: "tin can",
        confidence: 0.8
    )
    /// The model looked and would not name a bin.
    private static let unclear = CategoryReading(binID: nil, label: "blurred", confidence: 0.9)
    /// The model named a bin but hedged its way below the bar.
    private static let hedged = CategoryReading(
        binID: BinGuide.residual.id,
        label: "maybe a wrapper",
        confidence: 0.2
    )

    /// Holds the fake clock, so the coordinator and the test agree on "now" without either
    /// of them sleeping.
    private final class TestClock: @unchecked Sendable {
        var value: CFAbsoluteTime = 1_000
    }

    /// Collects the model calls the coordinator queues, so the test decides when they land
    /// instead of racing a detached task.
    private final class WorkQueue: @unchecked Sendable {
        private var work: [@Sendable () async -> Void] = []

        func append(_ item: @escaping @Sendable () async -> Void) { work.append(item) }

        func takeAll() -> [@Sendable () async -> Void] {
            defer { work.removeAll() }
            return work
        }

        var count: Int { work.count }
    }

    /// Drives the coordinator frame by frame at a fixed 30fps.
    private final class Harness {
        let coordinator: CategoryConfirmationCoordinator
        let confirmer: StubConfirmer

        private let queue = WorkQueue()
        private let testClock = TestClock()
        private let frameImage: CGImage?

        init(answers: [CategoryReading?]) {
            confirmer = StubConfirmer(answers: answers)
            coordinator = CategoryConfirmationCoordinator(service: confirmer)
            frameImage = Harness.makeFrame()

            let queue = self.queue
            let clock = testClock
            coordinator.isEnabled = true
            coordinator.minimumTrackFrames = 2
            coordinator.dispatch = { work in queue.append(work) }
            coordinator.clock = { clock.value }
        }

        var pendingRequests: Int { queue.count }

        func advance(_ seconds: CFAbsoluteTime) {
            testClock.value += seconds
        }

        @discardableResult
        func tick(
            _ tracks: [TrackedDetection]
        ) -> (tracks: [TrackedDetection], frame: ConfirmationFrame, records: [FoundationVerdictRecord]) {
            advance(1.0 / 30.0)
            let image = frameImage
            let result = coordinator.update(
                tracks: tracks,
                frameImage: { image },
                timestamp: testClock.value
            )
            collectedRecords.append(contentsOf: result.records)
            return result
        }

        func tick(_ tracks: [TrackedDetection], times: Int) {
            for _ in 0..<times { _ = tick(tracks) }
        }

        /// Every record the coordinator has handed out so far, in order.
        private(set) var collectedRecords: [FoundationVerdictRecord] = []

        /// Lets every queued model call finish.
        func settle() async {
            for work in queue.takeAll() {
                await work()
            }
        }

        private static func makeFrame() -> CGImage? {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: nil,
                      width: 640,
                      height: 480,
                      bitsPerComponent: 8,
                      bytesPerRow: 0,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                  )
            else { return nil }
            context.setFillColor(gray: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            return context.makeImage()
        }
    }

    private func track(
        id: Int = 1,
        classKey: String = "organic",
        centerX: CGFloat = 0.5,
        centerY: CGFloat = 0.5,
        side: CGFloat = 0.2,
        misses: Int = 0
    ) -> TrackedDetection {
        TrackedDetection(
            id: id,
            classKey: classKey,
            className: classKey,
            conf: 0.7,
            displayXywhn: CGRect(
                x: centerX - side / 2,
                y: centerY - side / 2,
                width: side,
                height: side
            ),
            misses: misses,
            rawClassKey: classKey,
            rawConf: 0.7
        )
    }

    // MARK: - Off means off

    @Test("disabled, tracks pass through untouched and nothing is asked")
    func disabledIsTransparent() async {
        let h = Harness(answers: [Self.organic])
        h.coordinator.isEnabled = false
        let input = [track(classKey: "residual")]
        let first = h.tick(input)
        _ = h.tick(input)
        await h.settle()
        #expect(first.tracks == input)
        #expect(first.frame.states.isEmpty)
        #expect(h.confirmer.calls == 0)
    }

    // MARK: - Asking

    @Test("an item is asked about once it has been seen for a few frames")
    func asksWhenSteady() async {
        let h = Harness(answers: [Self.organic])
        let first = h.tick([track()])
        #expect(first.frame.state(for: 1) == .idle)
        #expect(h.pendingRequests == 0)

        let second = h.tick([track()])
        #expect(second.frame.state(for: 1) == .thinking)
        #expect(h.pendingRequests == 1)

        await h.settle()
        #expect(h.confirmer.calls == 1)
    }

    @Test("a box too small to read is never sent")
    func tinyBoxesAreSkipped() async {
        let h = Harness(answers: [Self.organic])
        h.tick([track(side: 0.02)], times: 6)
        await h.settle()
        #expect(h.confirmer.calls == 0)
    }

    @Test("frozen boxes neither count towards steadiness nor get sent")
    func coastingIsNotEvidence() async {
        let h = Harness(answers: [Self.organic])
        h.tick([track(misses: 1)], times: 6)
        await h.settle()
        #expect(h.confirmer.calls == 0)
    }

    // MARK: - Locking

    @Test("the verdict replaces the detector's label")
    func verdictIsApplied() async {
        let h = Harness(answers: [Self.recyclable])
        h.tick([track(classKey: "organic")], times: 2)
        await h.settle()

        let result = h.tick([track(classKey: "organic")])
        #expect(result.tracks.first?.classKey == BinGuide.cleanInorganic.id)
        #expect(result.frame.state(for: 1) == .confirmed)
    }

    @Test("the verdict holds even as the detector keeps changing its mind")
    func verdictOutlastsDetectorFlipFlop() async {
        let h = Harness(answers: [Self.recyclable])
        h.tick([track(classKey: "organic")], times: 2)
        await h.settle()

        for label in ["organic", "residual", "organic", "residual"] {
            let result = h.tick([track(classKey: label)])
            #expect(result.tracks.first?.classKey == BinGuide.cleanInorganic.id)
        }
    }

    /// Everything that counts an item — the deposit detector above all — reads `vote`, so
    /// that is what has to carry the lock.
    @Test("the locked label is what the deposit layer will read")
    func lockDrivesTheVote() async {
        let h = Harness(answers: [Self.recyclable])
        h.tick([track(classKey: "organic")], times: 2)
        await h.settle()

        let locked = h.tick([track(classKey: "organic")]).tracks.first
        #expect(locked?.vote.classKey == BinGuide.cleanInorganic.id)
        #expect(locked?.confirmedBinID == BinGuide.cleanInorganic.id)
    }

    /// The session log records `rawClassKey`. Overwriting it would make the detector and the
    /// model impossible to compare after the fact, which is the whole point of running both.
    @Test("the detector's own opinion is still readable after a lock")
    func lockPreservesTheDetectorsLabel() async {
        let h = Harness(answers: [Self.recyclable])
        h.tick([track(classKey: "organic")], times: 2)
        await h.settle()

        let locked = h.tick([track(classKey: "organic")]).tracks.first
        #expect(locked?.rawClassKey == "organic")
        #expect(locked?.observedClassKey == "organic")
    }

    @Test("a confirmed item is never asked about twice")
    func confirmedItemsAreNotReasked() async {
        let h = Harness(answers: [Self.organic])
        h.tick([track()], times: 2)
        await h.settle()
        h.tick([track()], times: 20)
        await h.settle()
        #expect(h.confirmer.calls == 1)
    }

    // MARK: - One at a time

    @Test("only one request is with the model at a time")
    func requestsAreSerialised() async {
        let h = Harness(answers: [Self.organic, Self.recyclable])
        let both = [track(id: 1, centerX: 0.3), track(id: 2, centerX: 0.7)]
        h.tick(both, times: 2)
        #expect(h.pendingRequests == 1)

        let queued = h.tick(both)
        #expect(queued.frame.states.values.filter { $0 == .thinking }.count == 1)

        await h.settle()
        h.tick(both)
        #expect(h.pendingRequests == 1)
        await h.settle()
        #expect(h.confirmer.calls == 2)
    }

    @Test("the biggest item goes first, because that is the one being held up")
    func largestBoxIsAskedFirst() async {
        let h = Harness(answers: [Self.recyclable])
        let both = [
            track(id: 1, centerX: 0.3, side: 0.1),
            track(id: 2, centerX: 0.7, side: 0.3),
        ]
        h.tick(both, times: 2)
        await h.settle()

        let result = h.tick(both)
        #expect(result.frame.state(for: 2) == .confirmed)
        #expect(result.frame.state(for: 1) != .confirmed)
    }

    /// A wedged model would otherwise hold the single slot for good and switch the whole
    /// layer off without saying so.
    @Test("a request that never comes back does not stall the queue forever")
    func wedgedRequestReleasesTheSlot() {
        let h = Harness(answers: [Self.organic, Self.recyclable])
        h.coordinator.requestTimeout = 5
        let both = [
            track(id: 1, centerX: 0.3, side: 0.3),
            track(id: 2, centerX: 0.7, side: 0.2),
        ]
        h.tick(both, times: 2)
        #expect(h.pendingRequests == 1)

        // Nobody ever answers, so the queue is never settled. Once the timeout is up the
        // second item gets its turn anyway.
        h.advance(6)
        h.tick(both)
        #expect(h.pendingRequests == 2)
    }

    // MARK: - Surviving a dropout

    @Test("a verdict survives the tracker losing and renumbering the item")
    func verdictSurvivesABlink() async {
        let h = Harness(answers: [Self.recyclable])
        h.tick([track(id: 1, centerX: 0.5)], times: 2)
        await h.settle()
        #expect(h.tick([track(id: 1)]).frame.state(for: 1) == .confirmed)

        // Gone for a moment, then back a few pixels away under a fresh id.
        h.tick([])
        h.advance(0.3)
        let reacquired = h.tick([track(id: 2, centerX: 0.52)])
        #expect(reacquired.tracks.first?.classKey == BinGuide.cleanInorganic.id)
        #expect(reacquired.frame.state(for: 2) == .confirmed)

        await h.settle()
        #expect(h.confirmer.calls == 1)
    }

    /// The case a fixed radius got wrong. An item is normally lost *while being carried*, so
    /// the longer it was gone the further it will have travelled — and a carry towards a bin
    /// during a half-second dropout covers far more than a hand's width.
    @Test("an item carried during a long dropout is still the same item")
    func verdictFollowsACarriedItem() async {
        let h = Harness(answers: [Self.recyclable, Self.organic])
        h.tick([track(id: 1, centerX: 0.3)], times: 2)
        await h.settle()

        h.tick([])
        h.advance(0.5)
        let reacquired = h.tick([track(id: 2, classKey: "organic", centerX: 0.58)])
        #expect(reacquired.tracks.first?.classKey == BinGuide.cleanInorganic.id)
        #expect(reacquired.frame.state(for: 2) == .confirmed)
    }

    @Test("the search window still has a ceiling, however long the gap")
    func readoptionHasACeiling() async {
        let h = Harness(answers: [Self.recyclable, Self.organic])
        h.tick([track(id: 1, centerX: 0.2)], times: 2)
        await h.settle()

        h.tick([])
        h.advance(1.2)
        let stranger = h.tick([track(id: 2, classKey: "organic", centerX: 0.7)])
        #expect(stranger.tracks.first?.classKey == "organic")
        #expect(stranger.frame.state(for: 2) != .confirmed)
    }

    @Test("a different item appearing elsewhere does not inherit the verdict")
    func verdictDoesNotTransferAcrossTheFrame() async {
        let h = Harness(answers: [Self.recyclable, Self.organic])
        h.tick([track(id: 1, centerX: 0.2)], times: 2)
        await h.settle()

        h.tick([])
        let stranger = h.tick([track(id: 2, centerX: 0.9)])
        #expect(stranger.tracks.first?.classKey == "organic")
        #expect(stranger.frame.state(for: 2) != .confirmed)
    }

    @Test("a verdict is dropped once the item has been gone too long")
    func verdictExpires() async {
        let h = Harness(answers: [Self.recyclable, Self.organic])
        h.coordinator.lostGrace = 1.0
        h.tick([track(id: 1)], times: 2)
        await h.settle()

        h.tick([])
        h.advance(1.5)
        let returning = h.tick([track(id: 2, classKey: "residual")])
        #expect(returning.tracks.first?.classKey == "residual")
        #expect(returning.frame.state(for: 2) != .confirmed)
    }

    // MARK: - When the model will not say

    @Test("an unclear answer is retried after a pause, then left alone")
    func unclearAnswersAreRetriedThenDropped() async {
        let h = Harness(answers: [Self.unclear])
        h.coordinator.retryDelay = 1.0
        h.coordinator.maximumAttempts = 3

        for _ in 0..<3 {
            h.tick([track()], times: 2)
            await h.settle()
            h.advance(1.1)
        }
        #expect(h.confirmer.calls == 3)

        // The cap is reached, so no amount of further presence asks again.
        h.advance(10)
        h.tick([track()], times: 10)
        await h.settle()
        #expect(h.confirmer.calls == 3)
    }

    @Test("an unclear answer is not retried before the pause is up")
    func unclearAnswersRespectTheRetryDelay() async {
        let h = Harness(answers: [Self.unclear])
        h.coordinator.retryDelay = 5.0
        h.tick([track()], times: 2)
        await h.settle()

        h.tick([track()], times: 10)
        await h.settle()
        #expect(h.confirmer.calls == 1)
    }

    @Test("an item the model declined keeps the detector's own label")
    func unclearLeavesTheDetectorAlone() async {
        let h = Harness(answers: [Self.unclear])
        h.tick([track(classKey: "residual")], times: 2)
        await h.settle()
        let result = h.tick([track(classKey: "residual")])
        #expect(result.tracks.first?.classKey == "residual")
        #expect(result.frame.state(for: 1) == .idle)
    }

    // MARK: - The debug log

    @Test("an accepted answer is recorded with what the detector had said")
    func lockedAnswerIsRecorded() async {
        let h = Harness(answers: [Self.recyclable])
        h.tick([track(classKey: "organic")], times: 2)
        await h.settle()
        h.tick([track(classKey: "organic")])

        #expect(h.collectedRecords.count == 1)
        let record = h.collectedRecords.first
        #expect(record?.outcome == .locked(binID: BinGuide.cleanInorganic.id))
        #expect(record?.label == "tin can")
        #expect(record?.detectorClassKey == "organic")
        #expect(record?.disagreesWithDetector == true)
        #expect(record?.thumbnail != nil)
    }

    /// The two ways an answer gets thrown away look identical on screen, so the log has to
    /// tell them apart — that is most of why it exists.
    @Test("an unclear answer and a hedged one are recorded differently")
    func declinedAnswersSayWhy() async {
        let unclearRun = Harness(answers: [Self.unclear])
        unclearRun.tick([track()], times: 2)
        await unclearRun.settle()
        unclearRun.tick([track()])
        #expect(unclearRun.collectedRecords.first?.outcome == .declined(reason: "model answered unclear"))

        let hedgedRun = Harness(answers: [Self.hedged])
        hedgedRun.tick([track()], times: 2)
        await hedgedRun.settle()
        hedgedRun.tick([track()])
        #expect(hedgedRun.collectedRecords.first?.outcome == .declined(reason: "below 0.50 confidence"))
        #expect(hedgedRun.collectedRecords.first?.confidence == 0.2)
    }

    @Test("a call that throws is recorded rather than swallowed")
    func failuresAreRecorded() async {
        let h = Harness(answers: [nil])
        h.tick([track()], times: 2)
        await h.settle()
        h.tick([track()])

        #expect(h.collectedRecords.count == 1)
        if case .failed = h.collectedRecords.first?.outcome {} else {
            Issue.record("expected a failure record, got \(String(describing: h.collectedRecords.first?.outcome))")
        }
    }

    @Test("records are handed out exactly once")
    func recordsAreDrained() async {
        let h = Harness(answers: [Self.organic])
        h.tick([track()], times: 2)
        await h.settle()

        #expect(h.tick([track()]).records.count == 1)
        #expect(h.tick([track()]).records.isEmpty)
        #expect(h.collectedRecords.count == 1)
    }

    @Test("records still come through while the layer is being switched off")
    func recordsSurviveBeingDisabled() async {
        let h = Harness(answers: [Self.organic])
        h.tick([track()], times: 2)
        await h.settle()

        h.coordinator.isEnabled = false
        #expect(h.tick([track()]).records.count == 1)
    }

    // MARK: - Turning it off mid-flight

    @Test("switching off drops every locked verdict")
    func resetClearsVerdicts() async {
        let h = Harness(answers: [Self.recyclable])
        h.tick([track(classKey: "organic")], times: 2)
        await h.settle()

        h.coordinator.isEnabled = false
        let off = h.tick([track(classKey: "organic")])
        #expect(off.tracks.first?.classKey == "organic")

        h.coordinator.isEnabled = true
        let backOn = h.tick([track(classKey: "organic")])
        #expect(backOn.tracks.first?.classKey == "organic")
        #expect(backOn.frame.state(for: 1) != .confirmed)
    }
}
