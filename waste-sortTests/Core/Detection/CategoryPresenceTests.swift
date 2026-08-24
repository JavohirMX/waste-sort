import CoreGraphics
import Testing
@testable import waste_sort

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
        #expect(info.displayName == "RECYCLABLE")
        #expect(info.symbolName == "arrow.3.trianglepath")
    }

    @Test func dirtyRecyclableIsNotAPhysicalBin() {
        #expect(!BinGuide.all.contains(where: { $0.id == BinGuide.dirtyRecyclable.id }))
        #expect(BinGuide.bin(id: BinGuide.dirtyRecyclable.id).id == BinGuide.dirtyRecyclable.id)
        #expect(BinGuide.info(for: "dirty_recyclable").id == BinGuide.dirtyRecyclable.id)
        #expect(BinGuide.barBinIDs(for: BinGuide.dirtyRecyclable.id) == [
            BinGuide.residual.id,
            BinGuide.cleanInorganic.id,
        ])
    }

    @Test func dirtyRecyclableLightsResidualAndRecyclableOnTheBar() {
        let tracks = [
            TrackedDetection(
                id: 1,
                classKey: BinGuide.dirtyRecyclable.id,
                className: BinGuide.dirtyRecyclable.title,
                conf: 0.8,
                displayXywhn: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
            ),
        ]
        let counts = CategoryPresence.counts(from: tracks)
        #expect(CategoryPresence.isDetected(binID: BinGuide.residual.id, counts: counts))
        #expect(CategoryPresence.isDetected(binID: BinGuide.cleanInorganic.id, counts: counts))
        #expect(!CategoryPresence.isDetected(binID: BinGuide.organic.id, counts: counts))
        #expect(!CategoryPresence.isDetected(binID: BinGuide.dirtyRecyclable.id, counts: counts))
    }

    @Test func promptNamesDirtyRecyclableAsAModerateDirtGuess() {
        #expect(WasteCategoryPrompt.instructions.contains("dirtyRecyclable"))
        #expect(WasteCategoryPrompt.instructions.contains("40–50%"))
        #expect(BinGuide.cleanInorganic.instructions.contains("clean bags"))
    }
}
