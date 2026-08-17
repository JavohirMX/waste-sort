import CoreGraphics
import Testing
@testable import waste_sort

struct DetectionGeometryTests {
    private let topLeft = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)

    @Test func zeroDegreesIsIdentity() {
        let result = DetectionGeometry.rotateNormalized(topLeft, by: .zero)
        #expect(result == topLeft)
    }

    @Test func oneEightyMatchesFlipNormalized180() {
        let rotated = DetectionGeometry.rotateNormalized(topLeft, by: .oneEighty)
        let flipped = DetectionGeometry.flipNormalized180(topLeft)
        #expect(rotated == flipped)
        #expect(abs(rotated.minX - 0.7) < 1e-9)
        #expect(abs(rotated.minY - 0.8) < 1e-9)
        #expect(abs(rotated.width - 0.2) < 1e-9)
        #expect(abs(rotated.height - 0.1) < 1e-9)
    }

    @Test func ninetySwapsSizeAndMovesTopLeft() {
        let result = DetectionGeometry.rotateNormalized(topLeft, by: .ninety)
        #expect(abs(result.minX - 0.8) < 1e-9)
        #expect(abs(result.minY - 0.1) < 1e-9)
        #expect(abs(result.width - 0.1) < 1e-9)
        #expect(abs(result.height - 0.2) < 1e-9)
    }

    @Test func twoSeventySwapsSizeAndMovesTopLeft() {
        let result = DetectionGeometry.rotateNormalized(topLeft, by: .twoSeventy)
        #expect(abs(result.minX - 0.1) < 1e-9)
        #expect(abs(result.minY - 0.7) < 1e-9)
        #expect(abs(result.width - 0.1) < 1e-9)
        #expect(abs(result.height - 0.2) < 1e-9)
    }

    @Test func mirrorFlipsXOnly() {
        let result = DetectionGeometry.mirrorNormalized(topLeft)
        #expect(abs(result.minX - 0.7) < 1e-9)
        #expect(abs(result.minY - 0.1) < 1e-9)
        #expect(abs(result.width - 0.2) < 1e-9)
        #expect(abs(result.height - 0.1) < 1e-9)
    }
}
