import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import SwiftAprilTag

/// One detection pass, for the debug overlay and on-site tuning.
struct AprilTagFrameStats: Equatable, Sendable {
    var sourceWidth: Int = 0
    var sourceHeight: Int = 0
    /// Decodes the library returned before any of our filtering.
    var rawCount: Int = 0
    /// Decodes that survived margin, hamming, and geometry checks.
    var acceptedCount: Int = 0
    /// Strongest margin in the frame, or `nil` when nothing decoded at all. The single most
    /// useful number when aiming a camera: if this stays near the margin floor, the tags are
    /// at the edge of readable and want more resolution or a bigger print.
    var bestMargin: Float?
    /// Shortest edge of the accepted tags, in source pixels. Below ~15 px, decoding is luck.
    var smallestTagSidePixels: CGFloat?
    var detectionMilliseconds: Double = 0
}

/// Wraps `SwiftAprilTag` with the filtering the bin-openness pipeline needs.
///
/// The underlying C detector is not reentrant, so every call is serialized on this object's
/// lock and `AprilTagFramePipeline` keeps all live calls on one queue.
final class AprilTagDetector: @unchecked Sendable {
    private var detector: Detector?
    private let lock = NSLock()
    private var appliedTuning: AprilTagDetectionTuning?
    /// Guarded separately from `lock`: the UI polls stats every frame on the main thread and
    /// must never wait behind a detection pass that holds `lock` for tens of milliseconds.
    private let statsLock = NSLock()
    private var stats = AprilTagFrameStats()
    private var _tuning: AprilTagDetectionTuning

    init(
        familyName: String = "tag16h5",
        tuning: AprilTagDetectionTuning = AprilTagRangeProfile.far.tuning
    ) {
        self._tuning = tuning
        configureDetector(family: familyName)
    }

    var tuning: AprilTagDetectionTuning {
        lock.lock()
        defer { lock.unlock() }
        return _tuning
    }

    /// Last pass's diagnostics. Cheap to poll from the UI.
    var lastFrameStats: AprilTagFrameStats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return stats
    }

    func configureDetector(family: String) {
        lock.lock()
        defer { lock.unlock() }

        let tagFamily: TagFamily = family.lowercased().contains("16h5") ? .tag16h5 : .tag36h11
        do {
            let det = try Detector(families: [tagFamily])
            det.threadCount = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount))
            self.detector = det
            self.appliedTuning = nil
            applyTuningLocked()
        } catch {
            print("[AprilTagDetector] Error initializing detector: \(error)")
        }
    }

    func apply(tuning newTuning: AprilTagDetectionTuning) {
        lock.lock()
        defer { lock.unlock() }
        _tuning = newTuning
        applyTuningLocked()
    }

    /// Detects in a pixel buffer directly. Convenient for tests and one-off frames; the live
    /// path uses `extractLuminance` + `detect(luminance:)` so the expensive pass can move off
    /// the camera queue.
    func detect(
        in pixelBuffer: CVPixelBuffer,
        timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> [TrackedAprilTag] {
        var scratch: [UInt8] = []
        guard let size = Self.extractLuminance(from: pixelBuffer, into: &scratch) else { return [] }
        return scratch.withUnsafeBufferPointer { buffer -> [TrackedAprilTag] in
            guard let base = buffer.baseAddress else { return [] }
            return detect(
                luminance: base,
                width: size.width,
                height: size.height,
                stride: size.width,
                timestamp: timestamp
            )
        }
    }

    /// Detects in a tightly packed or strided 8-bit grayscale image.
    func detect(
        luminance: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        stride: Int,
        timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> [TrackedAprilTag] {
        lock.lock()
        defer { lock.unlock() }

        guard let detector, width > 0, height > 0, stride >= width else { return [] }
        let start = CFAbsoluteTimeGetCurrent()
        let raw = (try? detector.detect(
            luminanceBaseAddress: luminance,
            width: width,
            height: height,
            stride: stride
        )) ?? []

        let accepted = filterDetectionsLocked(raw, width: width, height: height, timestamp: timestamp)
        let pass = AprilTagFrameStats(
            sourceWidth: width,
            sourceHeight: height,
            rawCount: raw.count,
            acceptedCount: accepted.count,
            bestMargin: raw.map(\.decisionMargin).max(),
            smallestTagSidePixels: accepted
                .compactMap { Self.shortestSide(of: $0.corners, width: width, height: height) }
                .min(),
            detectionMilliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000
        )
        statsLock.lock()
        stats = pass
        statsLock.unlock()
        return accepted
    }

    /// Converts a BGRA, grayscale, or biplanar YUV pixel buffer to packed 8-bit luma, growing
    /// `destination` as needed. Cheap enough to run on the camera queue, which is the point:
    /// it snapshots the frame before the colour adjuster mutates it in place, so detection can
    /// run later on another queue against pristine pixels.
    @discardableResult
    static func extractLuminance(
        from pixelBuffer: CVPixelBuffer,
        into destination: inout [UInt8]
    ) -> (width: Int, height: Int)? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let required = width * height
        if destination.count < required {
            destination = [UInt8](repeating: 0, count: required)
        }

        if isLumaPlanar(format) {
            let planar = CVPixelBufferIsPlanar(pixelBuffer)
            let source = planar
                ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
                : CVPixelBufferGetBaseAddress(pixelBuffer)
            guard let source else { return nil }
            let rowBytes = planar
                ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                : CVPixelBufferGetBytesPerRow(pixelBuffer)
            guard rowBytes >= width else { return nil }
            let bytes = source.assumingMemoryBound(to: UInt8.self)
            destination.withUnsafeMutableBufferPointer { dest in
                guard let destPtr = dest.baseAddress else { return }
                for row in 0..<height {
                    memcpy(destPtr + row * width, bytes + row * rowBytes, width)
                }
            }
            return (width, height)
        }

        guard isBGRA(format), let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var ok = false
        destination.withUnsafeMutableBufferPointer { dest in
            guard let destPtr = dest.baseAddress else { return }
            var source = vImage_Buffer(
                data: baseAddress,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: bytesPerRow
            )
            var target = vImage_Buffer(
                data: destPtr,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width
            )
            // Rec. 601 luma weights in memory order for BGRA: B, G, R, A.
            var matrix: [Int16] = [114, 587, 299, 0]
            let status = vImageMatrixMultiply_ARGB8888ToPlanar8(
                &source,
                &target,
                &matrix,
                1000,
                nil,
                0,
                vImage_Flags(kvImageNoFlags)
            )
            ok = status == kvImageNoError
        }
        return ok ? (width, height) : nil
    }

    // MARK: - Internals

    private func applyTuningLocked() {
        guard let detector, appliedTuning != _tuning else { return }
        detector.quadDecimate = _tuning.quadDecimate
        detector.quadSigma = _tuning.quadSigma
        detector.refineEdges = _tuning.refineEdges
        detector.decodeSharpening = _tuning.decodeSharpening
        appliedTuning = _tuning
    }

    private static func isLumaPlanar(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
        format == kCVPixelFormatType_OneComponent8
    }

    private static func isBGRA(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB
    }

    private func filterDetectionsLocked(
        _ rawDetections: [Detection],
        width: Int,
        height: Int,
        timestamp: CFAbsoluteTime
    ) -> [TrackedAprilTag] {
        let invWidth = 1.0 / CGFloat(width)
        let invHeight = 1.0 / CGFloat(height)
        let tuning = _tuning

        return rawDetections.compactMap { det in
            // tag16h5 carries a minimum Hamming distance of only 5 between codes, and
            // SwiftAprilTag hardcodes 2 bits of correction, so a corrected decode is barely
            // better than a coin flip. Reject anything that needed correcting.
            guard det.decisionMargin >= tuning.minDecisionMargin,
                  det.hamming <= tuning.maxHamming,
                  det.corners.count == 4,
                  Self.isPlausibleQuad(det.corners, tuning: tuning)
            else { return nil }

            let normCenter = CGPoint(x: det.center.x * invWidth, y: det.center.y * invHeight)
            let normCorners = det.corners.map { CGPoint(x: $0.x * invWidth, y: $0.y * invHeight) }
            return TrackedAprilTag(
                id: det.id,
                center: normCenter,
                corners: normCorners,
                hamming: det.hamming,
                decisionMargin: det.decisionMargin,
                timestamp: timestamp
            )
        }
    }

    /// Rejects the degenerate quads that dominate weak-margin false positives: slivers,
    /// specks too small to hold 6x6 cells, and self-intersecting shapes.
    static func isPlausibleQuad(_ corners: [CGPoint], tuning: AprilTagDetectionTuning) -> Bool {
        guard corners.count == 4 else { return false }
        var shortest = CGFloat.greatestFiniteMagnitude
        var longest: CGFloat = 0
        for index in 0..<4 {
            let a = corners[index]
            let b = corners[(index + 1) % 4]
            let length = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
            shortest = min(shortest, length)
            longest = max(longest, length)
        }
        guard shortest >= tuning.minTagSidePixels else { return false }
        guard longest <= shortest * tuning.maxSideRatio else { return false }
        return isConvex(corners)
    }

    private static func isConvex(_ corners: [CGPoint]) -> Bool {
        var sign: CGFloat = 0
        for index in 0..<4 {
            let a = corners[index]
            let b = corners[(index + 1) % 4]
            let c = corners[(index + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if cross == 0 { continue }
            if sign == 0 {
                sign = cross
            } else if (cross > 0) != (sign > 0) {
                return false
            }
        }
        return sign != 0
    }

    private static func shortestSide(of corners: [CGPoint], width: Int, height: Int) -> CGFloat? {
        guard corners.count == 4 else { return nil }
        var shortest = CGFloat.greatestFiniteMagnitude
        for index in 0..<4 {
            let a = corners[index]
            let b = corners[(index + 1) % 4]
            let dx = (b.x - a.x) * CGFloat(width)
            let dy = (b.y - a.y) * CGFloat(height)
            shortest = min(shortest, (dx * dx + dy * dy).squareRoot())
        }
        return shortest
    }
}
