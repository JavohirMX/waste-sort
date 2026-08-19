import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import SwiftAprilTag

final class AprilTagDetector: @unchecked Sendable {
    private var detector: Detector?
    private let lock = NSLock()
    private var currentFamily: String = "tag16h5"
    private var lumaBuffer: [UInt8] = []

    init(familyName: String = "tag16h5") {
        self.currentFamily = familyName
        configureDetector(family: familyName)
    }

    func configureDetector(family: String) {
        lock.lock()
        defer { lock.unlock() }

        let tagFamily: TagFamily = family.lowercased().contains("16h5") ? .tag16h5 : .tag36h11
        do {
            let det = try Detector(families: [tagFamily])
            det.threadCount = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount))
            det.quadDecimate = 1.0 // Full resolution search
            det.quadSigma = 0.8    // Gaussian filter sensor noise
            det.refineEdges = true
            det.decodeSharpening = 0.25
            self.detector = det
            self.currentFamily = family
        } catch {
            print("[AprilTagDetector] Error initializing detector: \(error)")
        }
    }

    func detect(
        in pixelBuffer: CVPixelBuffer,
        timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> [TrackedAprilTag] {
        lock.lock()
        defer { lock.unlock() }

        guard let detector = self.detector else { return [] }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return [] }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let rawDetections: [Detection]

        if isPlanarYUV(pixelFormat) {
            rawDetections = (try? detector.detect(pixelBuffer: pixelBuffer, plane: 0)) ?? []
        } else if isRGBFormat(pixelFormat) {
            rawDetections = detectBGRA(detector: detector, pixelBuffer: pixelBuffer, width: width, height: height)
        } else {
            rawDetections = []
        }

        return filterDetections(rawDetections, width: width, height: height, timestamp: timestamp)
    }

    private func isPlanarYUV(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    private func isRGBFormat(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB
    }

    private func detectBGRA(
        detector: Detector,
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) -> [Detection] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let requiredSize = width * height
        if lumaBuffer.count < requiredSize {
            lumaBuffer = [UInt8](repeating: 0, count: requiredSize)
        }

        var results: [Detection] = []
        lumaBuffer.withUnsafeMutableBufferPointer { destBuffer in
            guard let destPtr = destBuffer.baseAddress else { return }
            var srcVImage = vImage_Buffer(
                data: baseAddress,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: bytesPerRow
            )
            var destVImage = vImage_Buffer(
                data: destPtr,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width
            )

            // Rec. 601 Luma matrix: B=114, G=587, R=299, A=0
            var matrix: [Int16] = [114, 587, 299, 0]
            let flags = vImage_Flags(kvImageNoFlags)
            let status = vImageMatrixMultiply_ARGB8888ToPlanar8(
                &srcVImage,
                &destVImage,
                &matrix,
                1000,
                nil,
                0,
                flags
            )
            if status == kvImageNoError {
                if let detections = try? detector.detect(
                    luminanceBaseAddress: destPtr,
                    width: width,
                    height: height,
                    stride: width
                ) {
                    results = detections
                }
            }
        }
        return results
    }

    private func filterDetections(
        _ rawDetections: [Detection],
        width: Int,
        height: Int,
        timestamp: CFAbsoluteTime
    ) -> [TrackedAprilTag] {
        let invWidth = 1.0 / CGFloat(width)
        let invHeight = 1.0 / CGFloat(height)

        let isSmallFamily = currentFamily.lowercased().contains("16h5")
        let minDecisionMargin: Float = isSmallFamily ? 35.0 : 25.0
        let maxHamming: Int = isSmallFamily ? 0 : 1

        return rawDetections.compactMap { det in
            guard det.decisionMargin >= minDecisionMargin, det.hamming <= maxHamming else { return nil }
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
}
