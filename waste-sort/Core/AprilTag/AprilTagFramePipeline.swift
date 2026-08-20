import CoreVideo
import Foundation

/// Runs AprilTag detection off the camera queue.
///
/// The camera queue is shared with YOLO: `VideoFrameColorProxy` forwards each buffer to the
/// model only after the tap returns, so a full-resolution AprilTag pass done inline would show
/// up directly as lost inference frames. Instead the tap does the one thing that must happen
/// synchronously - copying luma out before `FrameColorAdjuster` mutates the buffer in place -
/// and the detection itself runs on this pipeline's own queue.
///
/// Frames that arrive while a pass is still running are dropped rather than queued, so the
/// pipeline self-throttles to whatever rate the current resolution can sustain and never
/// builds a backlog of stale frames.
final class AprilTagFramePipeline: @unchecked Sendable {
    let detector: AprilTagDetector
    let temporalFilter: AprilTagTemporalFilter

    /// Called on the pipeline's queue with the tags that survived confirmation.
    var onTags: (([TrackedAprilTag], CFAbsoluteTime) -> Void)?

    private let queue = DispatchQueue(label: "com.ecodyssey.apriltag.detect", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    /// Owned by the camera queue while `busy` is false, by the detection queue while it is true.
    private var luma: [UInt8] = []
    private var lumaSize: (width: Int, height: Int) = (0, 0)
    private var droppedFrames: Int = 0

    init(
        detector: AprilTagDetector = AprilTagDetector(),
        temporalFilter: AprilTagTemporalFilter = AprilTagTemporalFilter()
    ) {
        self.detector = detector
        self.temporalFilter = temporalFilter
        applyMargins(detector.tuning)
    }

    func apply(tuning: AprilTagDetectionTuning) {
        detector.apply(tuning: tuning)
        applyMargins(tuning)
    }

    private func applyMargins(_ tuning: AprilTagDetectionTuning) {
        temporalFilter.instantTrustMargin = tuning.instantTrustMargin
        temporalFilter.strongMargin = tuning.strongMargin
    }

    /// Frames skipped because a pass was still running. A steadily climbing count means the
    /// range profile is heavier than the device can sustain.
    var droppedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedFrames
    }

    /// Call from the camera queue, before any in-place mutation of `pixelBuffer`.
    func submit(_ pixelBuffer: CVPixelBuffer, timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        lock.lock()
        if busy {
            droppedFrames &+= 1
            lock.unlock()
            return
        }
        busy = true
        lock.unlock()

        guard let size = AprilTagDetector.extractLuminance(from: pixelBuffer, into: &luma) else {
            finishPass()
            return
        }
        lumaSize = size

        queue.async { [weak self] in
            guard let self else { return }
            let tags = self.luma.withUnsafeBufferPointer { buffer -> [TrackedAprilTag] in
                guard let base = buffer.baseAddress else { return [] }
                return self.detector.detect(
                    luminance: base,
                    width: self.lumaSize.width,
                    height: self.lumaSize.height,
                    stride: self.lumaSize.width,
                    timestamp: timestamp
                )
            }
            let confirmed = self.temporalFilter.filter(tags, timestamp: timestamp)
            self.finishPass()
            self.onTags?(confirmed, timestamp)
        }
    }

    func reset() {
        temporalFilter.reset()
        lock.lock()
        droppedFrames = 0
        lock.unlock()
    }

    private func finishPass() {
        lock.lock()
        busy = false
        lock.unlock()
    }
}
