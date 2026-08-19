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
}
