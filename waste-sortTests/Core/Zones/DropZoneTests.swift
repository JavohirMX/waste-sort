import CoreGraphics
import Foundation
import Testing

@testable import waste_sort

@Suite("DropZone")
struct DropZoneTests {
    private func square() -> DropZone {
        DropZone(
            name: "Organic",
            binID: BinGuide.organic.id,
            corners: DropZone.rect(CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4))
        )
    }

    @Test("contains a point inside the quad")
    func containsInside() {
        #expect(square().contains(CGPoint(x: 0.4, y: 0.4)))
    }

    @Test("rejects points outside the quad")
    func rejectsOutside() {
        let zone = square()
        #expect(!zone.contains(CGPoint(x: 0.1, y: 0.4)))
        #expect(!zone.contains(CGPoint(x: 0.4, y: 0.9)))
        #expect(!zone.contains(CGPoint(x: 0.65, y: 0.4)))
    }

    @Test("handles a concave quad")
    func concave() {
        // A dart: the bottom-right corner is dragged inward past the diagonal.
        let zone = DropZone(
            name: "Dart",
            binID: BinGuide.residual.id,
            corners: [
                CGPoint(x: 0.0, y: 0.0),
                CGPoint(x: 1.0, y: 0.0),
                CGPoint(x: 0.5, y: 0.5),
                CGPoint(x: 0.0, y: 1.0)
            ]
        )
        #expect(zone.contains(CGPoint(x: 0.2, y: 0.2)))
        #expect(!zone.contains(CGPoint(x: 0.8, y: 0.8)))
    }

    @Test("clamps dragged corners back into the frame")
    func clamps() {
        var zone = square()
        zone.corners[0] = CGPoint(x: -0.3, y: 1.7)
        zone.clampToFrame()
        #expect(zone.corners[0] == CGPoint(x: 0, y: 1))
    }

    @Test("survives a Codable round trip")
    func codableRoundTrip() throws {
        let zone = square()
        let data = try JSONEncoder().encode([zone])
        let decoded = try JSONDecoder().decode([DropZone].self, from: data)
        #expect(decoded == [zone])
    }

    @Test("defaults cover every waste category without overlapping")
    func defaults() {
        let zones = DropZone.defaults()
        #expect(zones.count == BinGuide.all.count)
        #expect(Set(zones.map(\.binID)) == Set(BinGuide.all.map(\.id)))
        for zone in zones {
            #expect(zone.corners.count == 4)
            for corner in zone.corners {
                #expect(corner.x >= 0 && corner.x <= 1)
                #expect(corner.y >= 0 && corner.y <= 1)
            }
        }
        // Neighbouring defaults must not claim the same centre point.
        for zone in zones {
            let others = zones.filter { $0.id != zone.id }
            #expect(!others.contains { $0.contains(zone.centroid) })
        }
    }

    @Test(
        "defaults read left-to-right on screen under every preview transform",
        arguments: LivePreviewRotation.allCases
    )
    func defaultsFollowScreenOrder(rotation: LivePreviewRotation) {
        for mirror in [false, true] {
            let zones = DropZone.defaults(rotation: rotation, mirror: mirror)
            // Map each centroid forward through the preview transform to get where it
            // actually lands on screen, then read the row off in that order.
            let onScreen = zones.map { zone -> (binID: String, x: CGFloat, y: CGFloat) in
                var point = zone.centroid
                if mirror { point = DetectionGeometry.mirrorNormalized(point) }
                point = DetectionGeometry.rotateNormalized(point, by: rotation)
                return (zone.binID, point.x, point.y)
            }
            let order = onScreen.sorted { $0.x < $1.x }.map(\.binID)
            #expect(order == BinGuide.all.map(\.id))
            // …and the row sits in the lower half of the screen, not the upper.
            #expect(onScreen.allSatisfy { $0.y > 0.5 })
        }
    }

    @Test("the default 180° preview is what reversed the row before")
    func defaultsUnderOneEightyAreMirroredInImageSpace() {
        let upright = DropZone.defaults(rotation: .zero, mirror: false)
        let flipped = DropZone.defaults(rotation: .oneEighty, mirror: false)
        // Same categories in the same list order…
        #expect(upright.map(\.binID) == flipped.map(\.binID))
        // …but stored mirrored in image space, which is what cancels the rotation.
        let uprightX = upright.map(\.centroid.x)
        let flippedX = flipped.map(\.centroid.x)
        for (a, b) in zip(uprightX, flippedX) {
            #expect(abs((1 - a) - b) < 1e-9)
        }
    }
}
