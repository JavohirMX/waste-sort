import CoreGraphics
import Testing
@testable import waste_sort

struct PrimaryTrackSelectorTests {
    @Test func selectsLargestTrackWhenNoPrevious() {
        let small = track(id: 1, classKey: "organic", width: 0.1, height: 0.1)
        let large = track(id: 2, classKey: "residual", width: 0.4, height: 0.3)
        let selected = PrimaryTrackSelector.select(from: [small, large], previousID: nil)
        #expect(selected?.id == 2)
    }

    @Test func keepsPreviousUntilHysteresisExceeded() {
        let previous = track(id: 1, classKey: "residual", width: 0.30, height: 0.30)
        let challenger = track(id: 2, classKey: "organic", width: 0.32, height: 0.32)
        let selected = PrimaryTrackSelector.select(
            from: [previous, challenger],
            previousID: 1,
            hysteresis: 1.25
        )
        #expect(selected?.id == 1)
    }

    @Test func switchesWhenChallengerClearlyLarger() {
        let previous = track(id: 1, classKey: "residual", width: 0.20, height: 0.20)
        let challenger = track(id: 2, classKey: "organic", width: 0.40, height: 0.40)
        let selected = PrimaryTrackSelector.select(
            from: [previous, challenger],
            previousID: 1,
            hysteresis: 1.25
        )
        #expect(selected?.id == 2)
    }

    @Test func returnsNilWhenEmpty() {
        let selected = PrimaryTrackSelector.select(from: [], previousID: 3)
        #expect(selected == nil)
    }
}

struct CategoryPresenceTests {
    @Test func lightsDetectedCategoriesOnly() {
        let counts = ["residual": 2, "clean_inorganic": 1]
        #expect(CategoryPresence.isDetected(binID: "residual", counts: counts))
        #expect(CategoryPresence.isDetected(binID: "clean_inorganic", counts: counts))
        #expect(!CategoryPresence.isDetected(binID: "organic", counts: counts))
    }

    @Test func emptyCountsKeepAllDim() {
        for bin in BinGuide.all {
            #expect(!CategoryPresence.isDetected(binID: bin.id, counts: [:]))
        }
    }

    @Test func binGuideMapsCleanInorganic() {
        let info = BinGuide.info(for: "clean_inorganic")
        #expect(info.displayName == "INORGANIC")
        #expect(info.symbolName == "arrow.3.trianglepath")
    }
}

private func track(id: Int, classKey: String, width: CGFloat, height: CGFloat) -> TrackedDetection {
    TrackedDetection(
        id: id,
        classKey: classKey,
        className: classKey,
        conf: 0.9,
        displayXywhn: CGRect(x: 0.1, y: 0.1, width: width, height: height)
    )
}
