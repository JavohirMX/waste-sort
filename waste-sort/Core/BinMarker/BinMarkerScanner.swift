import CoreGraphics
import Foundation

/// Finds marker strips by walking straight lines through a frame.
///
/// The whole detector is one idea: a strip is the only thing in a bin room that produces a
/// short, tidy run of alternating bars with equal gaps between them. So instead of searching
/// for a shape, we walk rows and columns, compress each into runs, and keep the windows whose
/// rhythm is one we printed.
///
/// That buys two things a general marker detector does not have. It costs a single pass over a
/// quarter-resolution image, rather than the full-frame quad search AprilTag needs — which is
/// why that one had to be given its own queue and a drop-when-busy policy before it stopped
/// eating inference frames. And because the gaps between bars are all one unit wide, the scan
/// measures its own scale from them and never needs to be told how far away the bins are.
///
/// Not thread-safe by design: it owns reusable scratch buffers, so one instance belongs to one
/// queue. `BinMarkerFramePipeline` is what guarantees that.
nonisolated final class BinMarkerScanner {
    var config: BinMarkerConfig
    private(set) var lastFrameStats = BinMarkerFrameStats()

    var codes: [Int8] = []
    var classifierScratch = BinMarkerSampleClassifier.Scratch()
    var runs: [Run] = []
    var segments: [Segment] = []

    init(config: BinMarkerConfig = .standard) {
        self.config = config
    }

    /// Every strip visible in this frame.
    ///
    /// - Parameter inks: the palette to match against, already carrying any per-bin
    ///   calibration. Ignored under `BinMarkerStyle.mono`.
    func scan(
        _ image: BinMarkerImage,
        inks: [BinMarkerInk] = BinMarkerInk.all,
        timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> [BinMarkerDetection] {
        let start = CFAbsoluteTimeGetCurrent()
        var stats = BinMarkerFrameStats(sourceWidth: image.width, sourceHeight: image.height)

        guard image.isUsable else {
            finish(stats: &stats, from: start)
            return []
        }
        if config.style == .color, !image.hasChroma {
            // A monochrome source cannot carry a color marker. Silence here would read as
            // "every bin is shut", so the pass records why it found nothing.
            stats.missingChroma = true
            finish(stats: &stats, from: start)
            return []
        }

        segments.removeAll(keepingCapacity: true)
        let stride = max(1, config.scanStride)

        for y in Swift.stride(from: 0, to: image.height, by: stride) {
            stats.linesScanned += 1
            collectSegments(
                image: image,
                inks: inks,
                lineStart: y * image.width,
                step: 1,
                count: image.width,
                line: y,
                orientation: .horizontal,
                stats: &stats
            )
        }
        for x in Swift.stride(from: 0, to: image.width, by: stride) {
            stats.linesScanned += 1
            collectSegments(
                image: image,
                inks: inks,
                lineStart: x,
                step: image.width,
                count: image.height,
                line: x,
                orientation: .vertical,
                stats: &stats
            )
        }

        let detections = group(
            width: image.width,
            height: image.height,
            timestamp: timestamp
        )
        stats.acceptedCount = detections.count
        stats.largestUnitSamples = segments.map(\.unit).max()
        finish(stats: &stats, from: start)
        return detections
    }

    // MARK: - Helpers

    /// The printed unit, measured off the gaps — or nil when the gaps disagree with each other.
    ///
    /// Every gap on a strip is one unit wide, which makes them the only self-describing thing
    /// in the image and is why the scan never needs to know how far away the bins are. It also
    /// means a set of gaps that contradicts itself is a broken ruler, and nothing measured
    /// against it can be trusted — including a rhythm that happens to look right.
    func ruler(_ gapWidths: [Double]) -> Double? {
        guard let smallest = gapWidths.min(), let largest = gapWidths.max(), smallest > 0,
              largest / smallest <= config.maxGapSpread
        else { return nil }
        let unit = median(gapWidths)
        guard unit >= config.minUnitSamples, unit <= config.maxUnitSamples else { return nil }
        return unit
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private func finish(stats: inout BinMarkerFrameStats, from start: CFAbsoluteTime) {
        stats.detectionMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        lastFrameStats = stats
    }
}
