import CoreGraphics
import Foundation
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

    // MARK: - Point mapping (drop zone corners)

    @Test(arguments: LivePreviewRotation.allCases)
    func pointRotationMatchesRectBoundingBox(rotation: LivePreviewRotation) {
        let rect = DetectionGeometry.rotateNormalized(topLeft, by: rotation)
        let corners = [
            CGPoint(x: topLeft.minX, y: topLeft.minY),
            CGPoint(x: topLeft.maxX, y: topLeft.minY),
            CGPoint(x: topLeft.maxX, y: topLeft.maxY),
            CGPoint(x: topLeft.minX, y: topLeft.maxY),
        ].map { DetectionGeometry.rotateNormalized($0, by: rotation) }

        let minX = corners.map(\.x).min() ?? 0
        let minY = corners.map(\.y).min() ?? 0
        let maxX = corners.map(\.x).max() ?? 0
        let maxY = corners.map(\.y).max() ?? 0
        #expect(abs(rect.minX - minX) < 1e-9)
        #expect(abs(rect.minY - minY) < 1e-9)
        #expect(abs(rect.width - (maxX - minX)) < 1e-9)
        #expect(abs(rect.height - (maxY - minY)) < 1e-9)
    }

    @Test(arguments: LivePreviewRotation.allCases)
    func displayPointRoundTrips(rotation: LivePreviewRotation) {
        let sizes = [
            (CGSize(width: 1920, height: 1080), CGSize(width: 834, height: 1194)),
            (CGSize(width: 1080, height: 1920), CGSize(width: 1194, height: 834)),
            (CGSize(width: 1280, height: 720), CGSize(width: 1280, height: 720)),
        ]
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.2, y: 0.87),
            CGPoint(x: 1, y: 1),
        ]
        for (imageSize, viewSize) in sizes {
            for mirror in [false, true] {
                for point in points {
                    let view = DetectionGeometry.mapDisplayPoint(
                        normalized: point,
                        imageSize: imageSize,
                        viewSize: viewSize,
                        rotation: rotation,
                        mirror: mirror,
                        useAspectFill: true
                    )
                    let back = DetectionGeometry.mapNormalizedPoint(
                        viewPoint: view,
                        imageSize: imageSize,
                        viewSize: viewSize,
                        rotation: rotation,
                        mirror: mirror,
                        useAspectFill: true
                    )
                    #expect(abs(back.x - point.x) < 1e-6)
                    #expect(abs(back.y - point.y) < 1e-6)
                }
            }
        }
    }

    @Test(arguments: LivePreviewRotation.allCases)
    func displayPointAgreesWithRectMapping(rotation: LivePreviewRotation) {
        let imageSize = CGSize(width: 1920, height: 1080)
        let viewSize = CGSize(width: 834, height: 1194)
        let rect = CGRect(x: 0.25, y: 0.4, width: 0.2, height: 0.15)

        let mappedRect = DetectionGeometry.mapDisplayRect(
            normalized: rect,
            imageSize: imageSize,
            viewSize: viewSize,
            rotation: rotation,
            mirror: false,
            useAspectFill: true
        )
        let mappedCorners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ].map {
            DetectionGeometry.mapDisplayPoint(
                normalized: $0,
                imageSize: imageSize,
                viewSize: viewSize,
                rotation: rotation,
                mirror: false,
                useAspectFill: true
            )
        }
        let minX = mappedCorners.map(\.x).min() ?? 0
        let minY = mappedCorners.map(\.y).min() ?? 0
        #expect(abs(mappedRect.minX - minX) < 1e-6)
        #expect(abs(mappedRect.minY - minY) < 1e-6)
    }

    @Test func degenerateSizesMapToZeroInsteadOfNaN() {
        let point = DetectionGeometry.mapDisplayPoint(
            normalized: CGPoint(x: 0.5, y: 0.5),
            imageSize: .zero,
            viewSize: CGSize(width: 100, height: 100),
            rotation: .oneEighty,
            mirror: false,
            useAspectFill: true
        )
        #expect(point == .zero)
    }
}
