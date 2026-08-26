import CoreVideo
import Foundation

/// Runs marker detection off the camera queue.
///
/// Same shape as `AprilTagFramePipeline`, and for the same reason: the camera queue is shared
/// with YOLO, so anything done inline there shows up directly as lost inference frames. The
/// tap does only what must happen synchronously — reading the frame before
/// `FrameColorAdjuster` mutates it in place — and the scan runs here.
///
/// Frames arriving mid-pass are dropped rather than queued. A stale frame answers a question
/// nobody is asking any more, and a backlog would make the lid signal lag the lid.
nonisolated final class BinMarkerFramePipeline: @unchecked Sendable {
    let scanner: BinMarkerScanner
    let temporalFilter: BinMarkerTemporalFilter

    let dashScanner = BinMarkerDashScanner()

    /// Called on the pipeline's queue with the strips that survived confirmation.
    var onDetections: (([BinMarkerDetection], CFAbsoluteTime) -> Void)?
    /// Called instead, under the dash style. No confirmation gate: nine alternating runs of
    /// one pitch produced nothing false across the site's own frames, so a second sighting
    /// would only add latency to a signal that is already specific.
    var onDashRows: (([BinMarkerDashRow], CFAbsoluteTime) -> Void)?

    private let queue = DispatchQueue(label: "com.ecodyssey.binmarker.detect", qos: .userInitiated)
    private let sampler = BinMarkerFrameSampler()
    private let lock = NSLock()
    private var busy = false
    private var droppedFrames = 0
    private var unreadableFormat = false
    private var palette: [BinMarkerInk] = BinMarkerInk.all

    init(
        scanner: BinMarkerScanner = BinMarkerScanner(),
        temporalFilter: BinMarkerTemporalFilter = BinMarkerTemporalFilter()
    ) {
        self.scanner = scanner
        self.temporalFilter = temporalFilter
    }

    /// Frames skipped because a pass was still running. A steadily climbing count means the
    /// working grid is bigger than the device can sustain at this frame rate.
    var droppedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedFrames
    }

    /// Set when the camera hands over a pixel format the sampler cannot read. Surfaced in the
    /// UI rather than logged and forgotten: with no samples, every bin reads shut for ever.
    var formatFailureReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return unreadableFormat ? "Camera pixel format is not readable for marker detection." : nil
    }

    /// - Parameter inks: the palette to match against, with any on-site calibration folded in.
    func apply(config: BinMarkerConfig, dashConfig: BinMarkerDashConfig, inks: [BinMarkerInk]) {
        scanner.config = config
        dashScanner.config = dashConfig
        // The dash style reads no colour, so it takes the luma plane whole rather than meeting
        // chroma at half size. That is where its range comes from.
        sampler.lumaOnly = config.style.usesDashRows
        lock.lock()
        palette = inks
        lock.unlock()
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

        guard sampler.sample(pixelBuffer) else {
            lock.lock()
            unreadableFormat = true
            busy = false
            lock.unlock()
            return
        }
        lock.lock()
        unreadableFormat = false
        let inks = palette
        lock.unlock()

        let image = sampler.image
        let style = scanner.config.style
        queue.async { [weak self] in
            guard let self else { return }
            if style.usesDashRows {
                let rows = self.dashScanner.scan(image, timestamp: timestamp)
                self.lock.lock()
                self.busy = false
                self.lock.unlock()
                self.onDashRows?(rows, timestamp)
                return
            }
            let found = self.scanner.scan(image, inks: inks, timestamp: timestamp)
            let confirmed = self.temporalFilter.filter(found, style: style, timestamp: timestamp)
            self.lock.lock()
            self.busy = false
            self.lock.unlock()
            self.onDetections?(confirmed, timestamp)
        }
    }

    func reset() {
        temporalFilter.reset()
        lock.lock()
        droppedFrames = 0
        unreadableFormat = false
        lock.unlock()
    }
}
