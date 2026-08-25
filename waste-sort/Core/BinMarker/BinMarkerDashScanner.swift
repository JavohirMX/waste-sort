import CoreGraphics
import Foundation

/// One row of dashes found in a frame.
nonisolated struct BinMarkerDashRow: Equatable, Sendable {
    var orientation: BinMarkerOrientation
    /// Normalized 0…1, top-left origin, unflipped — the space `DropZone` uses.
    var bounds: CGRect
    /// Dashes counted, gaps excluded.
    var dashes: Int
    /// Mean dash-or-gap width in working-image samples. The number to watch when placing a
    /// print: it is what tells you whether the row is large enough for this distance.
    var pitchSamples: Double
    var lineCount: Int
    var timestamp: CFAbsoluteTime

    var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
}

/// Finds a printed row of equal, equally spaced dashes.
///
/// This is the third thing tried here and the first measured against the site rather than
/// against a blank canvas, which is why it looks so much plainer than the two before it.
///
/// It carries **no code at all** — no colour, no bar rhythm, nothing to decode. The camera and
/// the bins do not move, so the question a code was answering — *which bin?* — is already
/// answered by which calibrated window the row turns up in. What is left for the marker to be
/// is merely *unmistakable*, and a run of equal dashes is: on fifteen frames of the real room,
/// with nothing installed, a stretch of nine alternating runs of consistent width never once
/// occurred. Five runs occurred in the hundreds.
///
/// What that buys, beyond the false positives:
///
/// - **Range.** Nothing here measures a ratio between two widths, only that a row of widths
///   agree with each other, so dashes hold up at two samples across where the bar rhythm
///   needed six to twelve.
/// - **Occlusion.** Repetition is the whole design. An arm over the middle of the row, or a
///   drawer only part way out, still leaves a readable stretch — the count simply drops.
///
/// Not thread-safe: it owns scratch buffers, so one instance belongs to one queue.
nonisolated final class BinMarkerDashScanner {
    var config: BinMarkerDashConfig
    private(set) var lastFrameStats = BinMarkerFrameStats()

    private var codes: [Int8] = []
    private var classifierScratch = BinMarkerSampleClassifier.Scratch()
    private var runs: [Run] = []
    private var segments: [Segment] = []

    init(config: BinMarkerDashConfig = .standard) {
        self.config = config
    }

    func scan(
        _ image: BinMarkerImage,
        timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> [BinMarkerDashRow] {
        let start = CFAbsoluteTimeGetCurrent()
        var stats = BinMarkerFrameStats(sourceWidth: image.width, sourceHeight: image.height)
        guard image.isUsable else {
            finish(stats: &stats, from: start)
            return []
        }

        segments.removeAll(keepingCapacity: true)
        let rowStride = max(1, config.rowStride)
        let columnStride = max(1, config.columnStride)
        for y in Swift.stride(from: 0, to: image.height, by: rowStride) {
            stats.linesScanned += 1
            collect(image: image, lineStart: y * image.width, step: 1, count: image.width,
                    line: y, orientation: .horizontal, stats: &stats)
        }
        for x in Swift.stride(from: 0, to: image.width, by: columnStride) {
            stats.linesScanned += 1
            collect(image: image, lineStart: x, step: image.width, count: image.height,
                    line: x, orientation: .vertical, stats: &stats)
        }

        let rows = group(width: image.width, height: image.height, timestamp: timestamp)
        stats.acceptedCount = rows.count
        stats.largestUnitSamples = segments.map(\.pitch).max()
        finish(stats: &stats, from: start)
        return rows
    }

    // MARK: - One line

    private struct Run {
        var code: Int8
        var start: Int
        var length: Int
    }

    private struct Segment {
        var orientation: BinMarkerOrientation
        var line: Int
        var start: Int
        var end: Int
        var runs: Int
        var pitch: Double

        var length: Int { end - start }
    }

    private func collect(
        image: BinMarkerImage,
        lineStart: Int,
        step: Int,
        count: Int,
        line: Int,
        orientation: BinMarkerOrientation,
        stats: inout BinMarkerFrameStats
    ) {
        guard count > 0 else { return }
        var classifierConfig = BinMarkerConfig.standard
        classifierConfig.minMonoContrast = config.minContrast
        classifierConfig.monoWindowRadius = config.windowRadius
        BinMarkerSampleClassifier.classifyMono(
            gray: image.gray, start: lineStart, step: step, count: count,
            config: classifierConfig, into: &codes, scratch: &classifierScratch
        )
        encodeRuns(count: count)
        readRows(line: line, orientation: orientation, stats: &stats)
    }

    private func encodeRuns(count: Int) {
        runs.removeAll(keepingCapacity: true)
        var index = 0
        while index < count {
            let code = codes[index]
            var end = index + 1
            while end < count, codes[end] == code { end += 1 }
            runs.append(Run(code: code, start: index, length: end - index))
            index = end
        }
        // Fold away slivers, or the sub-pixel edge between a dash and the paper fences every
        // dash off from its neighbours and no stretch ever alternates cleanly.
        guard runs.count > 1 else { return }
        var cleaned: [Run] = []
        cleaned.reserveCapacity(runs.count)
        for run in runs {
            if run.length < config.minRunSamples, !cleaned.isEmpty {
                cleaned[cleaned.count - 1].length += run.length
                continue
            }
            if let previous = cleaned.last, previous.code == run.code {
                cleaned[cleaned.count - 1].length += run.length
                continue
            }
            cleaned.append(run)
        }
        runs = cleaned
    }

    /// Pulls out every maximal stretch of dark/light runs whose widths agree with each other.
    ///
    /// Agreement is the whole signature. Wood grain, printed packaging and clothing all produce
    /// alternating dark and light — what they do not produce is nine of them in a row at one
    /// pitch. The stretch is cut the moment a run breaks the agreement, so a row bending away
    /// under a wide-angle lens simply yields a shorter row rather than none.
    private func readRows(
        line: Int,
        orientation: BinMarkerOrientation,
        stats: inout BinMarkerFrameStats
    ) {
        var index = 0
        while index < runs.count {
            guard runs[index].code != BinMarkerCode.other else {
                index += 1
                continue
            }
            var last = index
            var narrowest = Double(runs[index].length)
            var widest = narrowest
            var total = narrowest
            var next = index + 1
            while next < runs.count,
                  runs[next].code != BinMarkerCode.other,
                  runs[next].code != runs[next - 1].code {
                let width = Double(runs[next].length)
                let low = min(narrowest, width)
                let high = max(widest, width)
                if high / low > config.maxPitchSpread { break }
                narrowest = low
                widest = high
                total += width
                last = next
                next += 1
            }

            let runCount = last - index + 1
            if runCount >= config.minRuns {
                stats.candidateCount += 1
                let pitch = total / Double(runCount)
                if pitch >= config.minPitchSamples, pitch <= config.maxPitchSamples {
                    segments.append(Segment(
                        orientation: orientation,
                        line: line,
                        start: runs[index].start,
                        end: runs[last].start + runs[last].length,
                        // A stretch of N alternating runs shows ceil(N/2) dashes when it opens
                        // and closes on a dash, which is what the printed row does.
                        runs: runCount,
                        pitch: pitch
                    ))
                }
            }
            index = last + 1
        }
    }

    // MARK: - Grouping

    private func group(width: Int, height: Int, timestamp: CFAbsoluteTime) -> [BinMarkerDashRow] {
        guard width > 0, height > 0 else { return [] }
        var rows: [BinMarkerDashRow] = []
        let lineSpan = max(config.rowStride, config.columnStride) * 2

        for orientation in [BinMarkerOrientation.horizontal, .vertical] {
            var open: [Cluster] = []
            var closed: [Cluster] = []
            for segment in segments.filter({ $0.orientation == orientation })
                .sorted(by: { $0.line < $1.line }) {
                for index in open.indices.reversed()
                where segment.line - open[index].lastLine > lineSpan {
                    closed.append(open.remove(at: index))
                }
                if let index = open.firstIndex(where: { $0.accepts(segment) }) {
                    open[index].add(segment)
                } else {
                    open.append(Cluster(segment))
                }
            }
            closed.append(contentsOf: open)

            for cluster in closed where cluster.segments.count >= config.minLines {
                guard let first = cluster.segments.first else { continue }
                let minLine = cluster.segments.map(\.line).min() ?? first.line
                let across = CGFloat(minLine)...CGFloat(cluster.lastLine + 1)
                let along = CGFloat(cluster.start)...CGFloat(cluster.end)
                let bounds: CGRect
                switch orientation {
                case .horizontal:
                    bounds = CGRect(
                        x: along.lowerBound / CGFloat(width),
                        y: across.lowerBound / CGFloat(height),
                        width: (along.upperBound - along.lowerBound) / CGFloat(width),
                        height: (across.upperBound - across.lowerBound) / CGFloat(height)
                    )
                case .vertical:
                    bounds = CGRect(
                        x: across.lowerBound / CGFloat(width),
                        y: along.lowerBound / CGFloat(height),
                        width: (across.upperBound - across.lowerBound) / CGFloat(width),
                        height: (along.upperBound - along.lowerBound) / CGFloat(height)
                    )
                }
                let count = Double(cluster.segments.count)
                // The median line's run count, not the maximum: one lucky scan line that ran
                // along a wood seam should not decide how long the row is.
                let runs = cluster.segments.map(\.runs).sorted()[cluster.segments.count / 2]
                rows.append(BinMarkerDashRow(
                    orientation: orientation,
                    bounds: bounds,
                    dashes: (runs + 1) / 2,
                    pitchSamples: cluster.segments.map(\.pitch).reduce(0, +) / count,
                    lineCount: cluster.segments.count,
                    timestamp: timestamp
                ))
            }
        }
        return rows.sorted { $0.bounds.minY < $1.bounds.minY }
    }

    private struct Cluster {
        var segments: [Segment]
        var lastLine: Int
        var start: Int
        var end: Int

        init(_ segment: Segment) {
            segments = [segment]
            lastLine = segment.line
            start = segment.start
            end = segment.end
        }

        func accepts(_ segment: Segment) -> Bool {
            let shared = min(end, segment.end) - max(start, segment.start)
            guard shared > 0 else { return false }
            return Double(shared) / Double(min(end - start, segment.length)) >= 0.5
        }

        mutating func add(_ segment: Segment) {
            segments.append(segment)
            lastLine = max(lastLine, segment.line)
            start = min(start, segment.start)
            end = max(end, segment.end)
        }
    }

    private func finish(stats: inout BinMarkerFrameStats, from start: CFAbsoluteTime) {
        stats.detectionMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        lastFrameStats = stats
    }
}
