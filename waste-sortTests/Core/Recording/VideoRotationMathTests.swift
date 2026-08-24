import AVFoundation
import Foundation
import Testing
@testable import waste_sort

@Suite("VideoRotationMath")
struct VideoRotationMathTests {
    @Test func targetAngleWrapsNegative() {
        #expect(VideoRotationMath.targetRotationAngle(baseAngle: 90, rotation: .twoSeventy) == 0)
    }

    @Test func targetAngleAddsBase() {
        #expect(VideoRotationMath.targetRotationAngle(baseAngle: 0, rotation: .oneEighty) == 180)
        #expect(VideoRotationMath.targetRotationAngle(baseAngle: 0, rotation: .ninety) == 90)
        #expect(VideoRotationMath.targetRotationAngle(baseAngle: 270, rotation: .oneEighty) == 90)
    }

    @Test func mirrorCombinesFrontCameraWithPreference() {
        // Semantics (unchanged from RecordingController): mirrored = isFront XOR preference.
        #expect(VideoRotationMath.shouldMirror(isFrontCamera: true, mirrorPreference: false))
        #expect(!VideoRotationMath.shouldMirror(isFrontCamera: true, mirrorPreference: true))
        #expect(VideoRotationMath.shouldMirror(isFrontCamera: false, mirrorPreference: true))
        #expect(!VideoRotationMath.shouldMirror(isFrontCamera: false, mirrorPreference: false))
        // Unknown position falls back to the user preference alone.
        #expect(VideoRotationMath.shouldMirror(isFrontCamera: nil, mirrorPreference: true))
        #expect(!VideoRotationMath.shouldMirror(isFrontCamera: nil, mirrorPreference: false))
    }

    @Test func legacyOrientationFlipsForRotations() {
        #expect(
            VideoRotationMath.legacyOrientation(base: .portrait, rotation: .zero) == .portrait
        )
        #expect(
            VideoRotationMath.legacyOrientation(base: .portrait, rotation: .oneEighty) == .portraitUpsideDown
        )
        #expect(
            VideoRotationMath.legacyOrientation(base: .landscapeLeft, rotation: .ninety) == .landscapeRight
        )
    }
}

@Suite("RecordingPhaseMirror")
struct RecordingPhaseMirrorTests {
    @Test func reflectsSetValues() async {
        let mirror = RecordingPhaseMirror()
        #expect(mirror.current == .idle)
        mirror.set(.recording)
        #expect(mirror.current == .recording)
        mirror.set(.idle)
        #expect(mirror.current == .idle)
    }
}
