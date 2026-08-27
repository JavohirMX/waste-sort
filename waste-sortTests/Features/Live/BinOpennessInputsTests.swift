import Testing

@testable import waste_sort

@Suite("BinOpennessInputs")
struct BinOpennessInputsTests {
    @Test("default leaves lid detectors on")
    func defaultDoesNotForceOpen() {
        let april = BinOpennessInputs()
        #expect(april.forceOpen == false)
        #expect(april.usesMarkers == false)
        #expect(april.usesTags(aprilTagEnabled: true))
        #expect(april.usesTags(aprilTagEnabled: false) == false)

        let markers = BinOpennessInputs(source: .marker)
        #expect(markers.usesMarkers)
        #expect(markers.usesTags(aprilTagEnabled: true) == false)
    }

    @Test("forceOpen disables both lid detectors")
    func forceOpenDisablesDetectors() {
        let april = BinOpennessInputs(forceOpen: true)
        #expect(april.usesMarkers == false)
        #expect(april.usesTags(aprilTagEnabled: true) == false)

        let markers = BinOpennessInputs(source: .marker, forceOpen: true)
        #expect(markers.usesMarkers == false)
        #expect(markers.usesTags(aprilTagEnabled: true) == false)
    }
}
