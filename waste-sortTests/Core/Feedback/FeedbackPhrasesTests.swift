import Foundation
import Testing
@testable import waste_sort

@Suite("GuidancePhrases")
struct GuidancePhrasesTests {
    @Test func depositConfirmationNaturalizesDisplayName() {
        #expect(GuidancePhrases.depositConfirmation(displayName: "ORGANIC") == "Organic bin")
        #expect(GuidancePhrases.depositConfirmation(displayName: "RECYCLABLE") == "Recyclable bin")
        #expect(GuidancePhrases.depositConfirmation(displayName: "RESIDUAL") == "Residual bin")
    }
}

@Suite("BarcodeGuidance")
struct BarcodeGuidanceTests {
    @Test func retailSymbologiesGetPackagingHint() {
        #expect(BarcodeGuidance.hint(for: "EAN-13").contains("packaging"))
        #expect(BarcodeGuidance.hint(for: "UPC-E").contains("packaging"))
        #expect(!BarcodeGuidance.hint(for: "EAN-13").contains("not recyclable"))
    }

    @Test func encodedLabelsAreNotRecyclable() {
        #expect(BarcodeGuidance.hint(for: "QR").contains("not recyclable"))
        #expect(BarcodeGuidance.hint(for: "DataMatrix").contains("not recyclable"))
    }

    @Test func unknownSymbologyGetsGenericHint() {
        #expect(BarcodeGuidance.hint(for: "").contains("material"))
        #expect(BarcodeGuidance.hint(for: "CODE39").contains("material"))
    }

    @Test func displayNameFallsBackForEmpty() {
        #expect(BarcodeGuidance.displayName(for: "") == "Barcode")
        #expect(BarcodeGuidance.displayName(for: "EAN-13") == "EAN-13")
    }
}
