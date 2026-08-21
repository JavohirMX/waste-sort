import CoreGraphics
import Foundation
import Testing
@testable import waste_sort

@Suite("AprilTagTemporalFilter Tests")
struct AprilTagTemporalFilterTests {
    private func makeTag(
        id: Int,
        center: CGPoint = CGPoint(x: 0.25, y: 0.25),
        margin: Float = 25.0
    ) -> TrackedAprilTag {
        TrackedAprilTag(
            id: id,
            center: center,
            corners: [
                CGPoint(x: center.x - 0.02, y: center.y - 0.02),
                CGPoint(x: center.x + 0.02, y: center.y - 0.02),
                CGPoint(x: center.x + 0.02, y: center.y + 0.02),
                CGPoint(x: center.x - 0.02, y: center.y + 0.02)
            ],
            hamming: 0,
            decisionMargin: margin,
            timestamp: 0
        )
    }

    private func makeFilter() -> AprilTagTemporalFilter {
        let filter = AprilTagTemporalFilter()
        filter.instantTrustMargin = 50.0
        filter.strongMargin = 30.0
        filter.requiredHits = 2
        return filter
    }

    @Test("A strong-margin tag is trusted on its very first frame")
    func instantTrust() {
        let filter = makeFilter()
        let accepted = filter.filter([makeTag(id: 4, margin: 60)], timestamp: 100.0)
        #expect(accepted.map(\.id) == [4])
    }

    @Test("A lone mid-margin sighting is suppressed until it repeats")
    func midMarginNeedsTwoHits() {
        let filter = makeFilter()
        let center = CGPoint(x: 0.3, y: 0.3)

        #expect(filter.filter([makeTag(id: 1, center: center, margin: 35)], timestamp: 100.0).isEmpty)
        let second = filter.filter([makeTag(id: 1, center: center, margin: 35)], timestamp: 100.05)
        #expect(second.map(\.id) == [1])
    }

    @Test("A weak-margin sighting needs one hit more than a strong one")
    func weakMarginNeedsThreeHits() {
        let filter = makeFilter()
        let center = CGPoint(x: 0.3, y: 0.3)

        #expect(filter.filter([makeTag(id: 2, center: center, margin: 21)], timestamp: 100.0).isEmpty)
        #expect(filter.filter([makeTag(id: 2, center: center, margin: 21)], timestamp: 100.05).isEmpty)
        let third = filter.filter([makeTag(id: 2, center: center, margin: 21)], timestamp: 100.10)
        #expect(third.map(\.id) == [2])
    }

    @Test("Sightings that jump around the frame never corroborate each other")
    func scatteredSightingsStaySuppressed() {
        let filter = makeFilter()
        let centers = [
            CGPoint(x: 0.1, y: 0.1),
            CGPoint(x: 0.8, y: 0.2),
            CGPoint(x: 0.4, y: 0.9),
            CGPoint(x: 0.9, y: 0.7)
        ]
        for (index, center) in centers.enumerated() {
            let accepted = filter.filter(
                [makeTag(id: 3, center: center, margin: 35)],
                timestamp: 100.0 + Double(index) * 0.05
            )
            #expect(accepted.isEmpty)
        }
    }

    @Test("Corroborating sightings older than the window stop counting")
    func staleSightingsExpire() {
        let filter = makeFilter()
        filter.windowSpan = 0.20
        let center = CGPoint(x: 0.3, y: 0.3)

        #expect(filter.filter([makeTag(id: 5, center: center, margin: 35)], timestamp: 100.0).isEmpty)
        // 0.5s later the first sighting has aged out, so this is a lone hit again.
        #expect(filter.filter([makeTag(id: 5, center: center, margin: 35)], timestamp: 100.5).isEmpty)
    }

    @Test("A confirmed tag stays trusted through flicker without re-confirming")
    func confirmationSurvivesDropouts() {
        let filter = makeFilter()
        filter.confirmationTTL = 2.0
        let center = CGPoint(x: 0.3, y: 0.3)

        _ = filter.filter([makeTag(id: 6, center: center, margin: 35)], timestamp: 100.0)
        #expect(filter.filter([makeTag(id: 6, center: center, margin: 35)], timestamp: 100.05).map(\.id) == [6])

        // Gone for a stretch longer than the corroboration window, then back as a single hit.
        let reappearance = filter.filter([makeTag(id: 6, center: center, margin: 35)], timestamp: 101.0)
        #expect(reappearance.map(\.id) == [6])
    }

    @Test("Confirmation lapses once the TTL passes")
    func confirmationExpires() {
        let filter = makeFilter()
        filter.confirmationTTL = 0.5
        let center = CGPoint(x: 0.3, y: 0.3)

        _ = filter.filter([makeTag(id: 7, center: center, margin: 35)], timestamp: 100.0)
        #expect(filter.filter([makeTag(id: 7, center: center, margin: 35)], timestamp: 100.05).map(\.id) == [7])

        let afterTTL = filter.filter([makeTag(id: 7, center: center, margin: 35)], timestamp: 102.0)
        #expect(afterTTL.isEmpty)
    }

    @Test("Each tag in a bin group confirms independently")
    func multiTagGroupConfirmsIndependently() {
        let filter = makeFilter()
        let centers = [
            0: CGPoint(x: 0.20, y: 0.30),
            1: CGPoint(x: 0.30, y: 0.30),
            2: CGPoint(x: 0.40, y: 0.30)
        ]

        // Tag #1 is crisp; #0 and #2 are marginal and need corroboration.
        let first = filter.filter(
            [
                makeTag(id: 0, center: centers[0]!, margin: 35),
                makeTag(id: 1, center: centers[1]!, margin: 60),
                makeTag(id: 2, center: centers[2]!, margin: 35)
            ],
            timestamp: 100.0
        )
        #expect(first.map(\.id) == [1])

        let second = filter.filter(
            [
                makeTag(id: 0, center: centers[0]!, margin: 35),
                makeTag(id: 1, center: centers[1]!, margin: 60),
                makeTag(id: 2, center: centers[2]!, margin: 35)
            ],
            timestamp: 100.05
        )
        #expect(second.map(\.id).sorted() == [0, 1, 2])
    }

    @Test("Reset drops all confirmations")
    func resetClearsConfirmations() {
        let filter = makeFilter()
        let center = CGPoint(x: 0.3, y: 0.3)

        _ = filter.filter([makeTag(id: 8, center: center, margin: 35)], timestamp: 100.0)
        _ = filter.filter([makeTag(id: 8, center: center, margin: 35)], timestamp: 100.05)
        filter.reset()

        #expect(filter.filter([makeTag(id: 8, center: center, margin: 35)], timestamp: 100.10).isEmpty)
    }
}
