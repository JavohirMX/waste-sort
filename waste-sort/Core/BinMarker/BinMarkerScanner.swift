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

    private var codes: [Int8] = []
    private var classifierScratch = BinMarkerSampleClassifier.Scratch()
    private var runs: [Run] = []
    private var segments: [Segment] = []

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

    // MARK: - One scan line

    private struct Run {
        var code: Int8
        var start: Int
        var length: Int
    }

    /// A strip as seen by a single scan line.
    private struct Segment {
        var orientation: BinMarkerOrientation
        var line: Int
        var start: Int
        /// Exclusive.
        var end: Int
        /// Index into the ink palette, or -1 under the mono style.
        var inkIndex: Int
        /// Nil when the bars had merged too far to read a rhythm and only the ink identified
        /// the strip.
        var patternID: Int?
        var unit: Double
        var cb: Double
        var cr: Double

        var length: Int { end - start }
    }

    private func collectSegments(
        image: BinMarkerImage,
        inks: [BinMarkerInk],
        lineStart: Int,
        step: Int,
        count: Int,
        line: Int,
        orientation: BinMarkerOrientation,
        stats: inout BinMarkerFrameStats
    ) {
        guard count > 0 else { return }

        switch config.style {
        case .color:
            guard let chroma = image.chroma else { return }
            BinMarkerSampleClassifier.classifyColor(
                chroma: chroma,
                start: lineStart,
                step: step,
                count: count,
                inks: inks,
                config: config,
                into: &codes
            )
        case .mono:
            BinMarkerSampleClassifier.classifyMono(
                gray: image.gray,
                start: lineStart,
                step: step,
                count: count,
                config: config,
                into: &codes,
                scratch: &classifierScratch
            )
        }

        encodeRuns(count: count)
        readWindows(
            image: image,
            lineStart: lineStart,
            step: step,
            line: line,
            orientation: orientation,
            stats: &stats
        )
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
        smoothRuns()
    }

    /// Absorbs runs too short to be anything, then re-merges whatever that leaves adjacent.
    ///
    /// The boundary between a printed bar and the white beside it does not land on a pixel
    /// edge. It smears across one or two samples whose chroma is neither the ink's nor the
    /// paper's — and chroma arrives from the camera at half resolution, so those samples are
    /// twice as wide as they look. Without this pass every real bar would be fenced off by a
    /// sliver of "neither", and no window would ever alternate cleanly enough to be read.
    private func smoothRuns() {
        let minimum = max(1, config.minRunSamples)
        guard runs.count > 1 else { return }

        var cleaned: [Run] = []
        cleaned.reserveCapacity(runs.count)
        for run in runs {
            if run.length < minimum, var previous = cleaned.last {
                previous.length += run.length
                cleaned[cleaned.count - 1] = previous
                continue
            }
            if let previous = cleaned.last, previous.code == run.code {
                cleaned[cleaned.count - 1].length += run.length
                continue
            }
            cleaned.append(run)
        }
        // A short leading run has no previous to fold into, so it survives the loop above.
        if let first = cleaned.first, first.length < minimum, cleaned.count > 1 {
            cleaned[1].start = first.start
            cleaned[1].length += first.length
            cleaned.removeFirst()
        }
        runs = cleaned
    }

    /// Walks the run list, pulling out every maximal ink/gap/ink alternation and keeping the
    /// ones shaped like a strip we printed.
    private func readWindows(
        image: BinMarkerImage,
        lineStart: Int,
        step: Int,
        line: Int,
        orientation: BinMarkerOrientation,
        stats: inout BinMarkerFrameStats
    ) {
        var index = 0
        while index < runs.count {
            guard runs[index].code >= BinMarkerCode.firstInk else {
                index += 1
                continue
            }
            let ink = runs[index].code
            // Extend while the pattern keeps alternating ink, gap, ink — with the *same* ink
            // throughout. A strip is printed in one color; a run of mixed colors is the room.
            //
            // The gap width has to stay put as well, and that guard is doing real work: two
            // bins side by side are separated by a stretch of background that classifies as
            // gap just like the millimetres between bars do. Without a width bound the scan
            // would happily swallow the wall between two strips and report one impossible
            // marker spanning both.
            var last = index
            var next = index + 1
            var firstGap: Double?
            while next + 1 < runs.count,
                  runs[next].code == BinMarkerCode.gap,
                  runs[next + 1].code == ink {
                let width = Double(runs[next].length)
                if let reference = firstGap {
                    let ratio = max(width / reference, reference / width)
                    guard ratio <= config.maxGapSpread else { break }
                } else {
                    firstGap = width
                }
                last = next + 1
                next += 2
            }

            let barCount = (last - index) / 2 + 1
            stats.candidateCount += 1
            if let segment = makeSegment(
                image: image,
                lineStart: lineStart,
                step: step,
                line: line,
                orientation: orientation,
                firstRun: index,
                lastRun: last,
                barCount: barCount,
                inkCode: ink
            ) {
                segments.append(segment)
            }
            index = last + 1
        }
    }

    private func makeSegment(
        image: BinMarkerImage,
        lineStart: Int,
        step: Int,
        line: Int,
        orientation: BinMarkerOrientation,
        firstRun: Int,
        lastRun: Int,
        barCount: Int,
        inkCode: Int8
    ) -> Segment? {
        guard barCount >= 2 else { return nil }

        var gapWidths: [Double] = []
        var barWidths: [Double] = []
        gapWidths.reserveCapacity(barCount - 1)
        barWidths.reserveCapacity(barCount)
        var run = firstRun
        while run <= lastRun {
            if runs[run].code == BinMarkerCode.gap {
                gapWidths.append(Double(runs[run].length))
            } else {
                barWidths.append(Double(runs[run].length))
            }
            run += 1
        }
        guard let smallestGap = gapWidths.min(), let largestGap = gapWidths.max(),
              smallestGap > 0
        else { return nil }

        // The gaps are the ruler. If they disagree with each other, the ruler is broken and
        // nothing measured against it can be trusted — including a rhythm that happens to
        // look right.
        guard largestGap / smallestGap <= config.maxGapSpread else { return nil }
        let unit = median(gapWidths)
        guard unit >= config.minUnitSamples, unit <= config.maxUnitSamples else { return nil }

        let patternID = resolvePattern(barWidths: barWidths, unit: unit)
        if patternID == nil {
            // No readable rhythm. Only the color style can go on from here, because only it
            // has a second, independent way to say which bin this is.
            guard config.style.allowsInkOnlyIdentity,
                  config.allowDegradedColor,
                  barCount >= config.minDegradedBars
            else { return nil }
        }

        let start = runs[firstRun].start
        let end = runs[lastRun].start + runs[lastRun].length
        var cbSum = 0.0
        var crSum = 0.0
        var samples = 0
        if let chroma = image.chroma {
            var barRun = firstRun
            while barRun <= lastRun {
                if runs[barRun].code >= BinMarkerCode.firstInk {
                    for offset in 0..<runs[barRun].length {
                        let pixel = lineStart + (runs[barRun].start + offset) * step
                        cbSum += Double(chroma[pixel * 2])
                        crSum += Double(chroma[pixel * 2 + 1])
                        samples += 1
                    }
                }
                barRun += 1
            }
        }

        return Segment(
            orientation: orientation,
            line: line,
            start: start,
            end: end,
            inkIndex: config.style == .mono ? -1 : Int(inkCode),
            patternID: patternID,
            unit: unit,
            cb: samples > 0 ? cbSum / Double(samples) : 128,
            cr: samples > 0 ? crSum / Double(samples) : 128
        )
    }

    /// Collapses measured bar widths onto the printed 1-or-2 units and looks the result up.
    ///
    /// Returns nil for anything that is not exactly one of our rhythms — including a full set
    /// of five bars whose widths do not line up. Five bars in the wrong proportions is not a
    /// strip read badly; it is something else entirely, and naming a bin from it would credit
    /// a deposit to the wrong place.
    private func resolvePattern(barWidths: [Double], unit: Double) -> Int? {
        guard barWidths.count == BinMarkerPattern.barCount else { return nil }
        var units: [Int] = []
        units.reserveCapacity(barWidths.count)
        for width in barWidths {
            let measured = width / unit
            guard measured >= config.minBarUnits, measured <= config.maxBarUnits else { return nil }
            units.append(measured >= config.wideThreshold ? 2 : 1)
        }
        return BinMarkerPattern.matching(units)?.id
    }

    // MARK: - Grouping

    /// Merges the per-line segments into strips.
    ///
    /// A strip is many samples tall, so a real one is crossed by several scan lines that all
    /// say the same thing in the same place. One line saying it alone is noise, and this is
    /// where that gets thrown away.
    private func group(width: Int, height: Int, timestamp: CFAbsoluteTime) -> [BinMarkerDetection] {
        guard width > 0, height > 0 else { return [] }
        var byKey: [String: [Segment]] = [:]
        for segment in segments {
            let key = "\(segment.orientation.rawValue)|\(segment.inkIndex)|\(segment.patternID ?? -1)"
            byKey[key, default: []].append(segment)
        }

        var detections: [BinMarkerDetection] = []
        let lineSpan = max(1, config.scanStride) * 2

        for (_, group) in byKey {
            // Several clusters have to stay open at once. Two bins carrying the same rhythm in
            // the same ink land in this bucket together, and their segments interleave line by
            // line — matching each new segment against only the most recent one would let the
            // two strips knock each other down to single-line clusters and discard both.
            var open: [Cluster] = []
            var closed: [Cluster] = []

            for segment in group.sorted(by: { $0.line < $1.line }) {
                for index in open.indices.reversed() where segment.line - open[index].lastLine > lineSpan {
                    closed.append(open.remove(at: index))
                }
                if let index = open.firstIndex(where: { $0.accepts(segment) }) {
                    open[index].add(segment)
                } else {
                    open.append(Cluster(segment))
                }
            }
            closed.append(contentsOf: open)

            for cluster in closed {
                guard cluster.segments.count >= config.minLines,
                      let first = cluster.segments.first
                else { continue }
                let minLine = cluster.segments.map(\.line).min() ?? first.line
                let maxLine = cluster.lastLine
                let minStart = cluster.start
                let maxEnd = cluster.end

                let along = CGFloat(minStart)...CGFloat(maxEnd)
                let across = CGFloat(minLine)...CGFloat(maxLine + 1)
                let bounds: CGRect
                switch first.orientation {
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
                detections.append(
                    BinMarkerDetection(
                        patternID: first.patternID,
                        inkID: first.inkIndex >= 0 && first.inkIndex < BinMarkerInk.all.count
                            ? BinMarkerInk.all[first.inkIndex].id
                            : nil,
                        orientation: first.orientation,
                        bounds: bounds,
                        lineCount: cluster.segments.count,
                        unitSamples: cluster.segments.map(\.unit).reduce(0, +) / count,
                        chroma: CGPoint(
                            x: cluster.segments.map(\.cb).reduce(0, +) / count,
                            y: cluster.segments.map(\.cr).reduce(0, +) / count
                        ),
                        timestamp: timestamp
                    )
                )
            }
        }

        return detections.sorted { $0.bounds.minY < $1.bounds.minY }
    }

    /// Scan lines of one strip, accumulated as they arrive.
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

        /// Whether `segment` lies over the same stretch this cluster already covers.
        ///
        /// Measured against the *narrower* of the two, so a scan line that catches only part
        /// of the strip still joins the cluster it belongs to instead of starting a rival.
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

    // MARK: - Helpers

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
