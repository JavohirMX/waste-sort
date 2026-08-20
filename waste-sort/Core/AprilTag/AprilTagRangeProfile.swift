import AVFoundation
import CoreGraphics
import Foundation

/// Detector knobs that trade throughput for range.
///
/// AprilTag range is decided almost entirely by how many pixels land across a tag, so the
/// two settings that matter at distance are the capture resolution and `quadDecimate`.
struct AprilTagDetectionTuning: Equatable, Sendable {
    /// Downscale factor applied before quad detection. `1.0` scans at full resolution and is
    /// required for distant tags; `2.0` is 3-4x faster but halves the pixels across a tag.
    var quadDecimate: Float
    /// Gaussian applied before quad detection. Positive blurs (denoises), negative sharpens.
    /// Distant tags lose more to blur than they gain in noise rejection.
    var quadSigma: Float
    /// Sharpening applied to the decoded bit samples. Helps small tags decode.
    var decodeSharpening: Double
    var refineEdges: Bool
    /// Reject decodes weaker than this. Lower admits more distant tags and more false
    /// positives; `AprilTagTemporalFilter` is what makes the low values safe.
    var minDecisionMargin: Float
    /// Decodes at or above this margin skip the temporal confirmation gate entirely, so
    /// close, crisp tags still register on the very first frame.
    var instantTrustMargin: Float
    /// Decodes at or above this margin need only `AprilTagTemporalFilter.requiredHits`
    /// corroborating sightings; weaker ones need `requiredHits + 1`.
    var strongMargin: Float
    var maxHamming: Int
    /// Shortest tag edge, in source pixels, that is still considered decodable.
    var minTagSidePixels: CGFloat
    /// Longest edge / shortest edge ceiling. Rejects the slivers that dominate tag16h5's
    /// false positives without rejecting genuinely oblique views.
    var maxSideRatio: CGFloat
}

/// How far the camera sits from the bins.
///
/// The bins carry `AprilTagConfig.tagsPerBinGroup` tags each and any one of them means "open",
/// so range, not per-tag certainty, is the binding constraint.
enum AprilTagRangeProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case near
    case far
    case veryFar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .near: return "Near"
        case .far: return "Far"
        case .veryFar: return "Very far"
        }
    }

    var detail: String {
        switch self {
        case .near:
            return "720p, half-resolution scan. Lightest on frame rate; camera within about 1.5 m of the bins."
        case .far:
            return "1080p, full-resolution scan. Reaches roughly 3-4 m with 5-6 cm tags."
        case .veryFar:
            return "4K, full-resolution scan with sharpening. Longest reach, heaviest on frame rate."
        }
    }

    /// Presets are tried in order; the first the active camera accepts wins.
    var captureSessionPresets: [AVCaptureSession.Preset] {
        switch self {
        case .near: return [.hd1280x720, .high]
        case .far: return [.hd1920x1080, .high, .hd1280x720]
        case .veryFar: return [.hd4K3840x2160, .hd1920x1080, .high, .hd1280x720]
        }
    }

    var tuning: AprilTagDetectionTuning {
        switch self {
        case .near:
            return AprilTagDetectionTuning(
                quadDecimate: 2.0,
                quadSigma: 0.8,
                decodeSharpening: 0.25,
                refineEdges: true,
                minDecisionMargin: 35.0,
                instantTrustMargin: 50.0,
                strongMargin: 42.0,
                maxHamming: 0,
                minTagSidePixels: 8.0,
                maxSideRatio: 4.0
            )
        case .far:
            return AprilTagDetectionTuning(
                quadDecimate: 1.0,
                quadSigma: 0.0,
                decodeSharpening: 0.35,
                refineEdges: true,
                minDecisionMargin: 20.0,
                instantTrustMargin: 50.0,
                strongMargin: 30.0,
                maxHamming: 0,
                minTagSidePixels: 10.0,
                maxSideRatio: 4.0
            )
        case .veryFar:
            return AprilTagDetectionTuning(
                quadDecimate: 1.0,
                quadSigma: -0.4,
                decodeSharpening: 0.55,
                refineEdges: true,
                minDecisionMargin: 14.0,
                instantTrustMargin: 50.0,
                strongMargin: 24.0,
                maxHamming: 0,
                minTagSidePixels: 10.0,
                maxSideRatio: 5.0
            )
        }
    }
}
