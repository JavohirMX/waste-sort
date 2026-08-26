import CoreGraphics
import Foundation

// MARK: - Grouping rows and chevron shape checks

extension BinMarkerDashScanner {

    func group(width: Int, height: Int, timestamp: CFAbsoluteTime) -> [BinMarkerDashRow] {
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
                guard !config.shape.requiresShapeCheck || isChevron(cluster.segments) else {
                    continue
                }
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

    /// Whether the row bends: offset ramping one way through the top of the row and the
    /// opposite way through the bottom.
    ///
    /// This is the only place the scanner looks *across* scan lines rather than along one, and
    /// it is where the marker stops being merely tidy and becomes unforgeable. A straight edge
    /// in the scene — wood grain, a counter lip, a sleeve — has one slope, and in perspective a
    /// third of the room's accidental rows do look convincingly sheared. Not one of them can
    /// reverse that slope at a midline. On the site's frames, 477 candidate rows at a reckless
    /// five-run threshold, none passing.
    ///
    /// Both edges of the row are offered, and either may carry the verdict. A drawer reveals
    /// the row by sliding it out from under the counter, so while it is opening the leading
    /// edge is the counter's straight lip rather than the print — and a straight edge is
    /// exactly what this test is built to reject. The trailing edge is the printed one, and
    /// that is the half that answers.
    private func isChevron(_ segments: [Segment]) -> Bool {
        // One segment per scan line, the longest of them. A line that contributed two is a
        // line where something crossed the row and split it, and neither fragment begins
        // where the row begins — feeding both to the fit puts a false step in the middle of
        // an otherwise clean ramp.
        var longest: [Int: Segment] = [:]
        for segment in segments {
            if let existing = longest[segment.line], existing.length >= segment.length {
                continue
            }
            longest[segment.line] = segment
        }
        guard longest.count >= config.shape.minLines else { return false }
        let sorted = longest.values.sorted { $0.line < $1.line }
        let lines = sorted.map { Double($0.line) }
        return bends(lines, sorted.map { Double($0.start) })
            || bends(lines, sorted.map { Double($0.end) })
    }

    /// Whether one edge, traced against its scan lines, is a V.
    ///
    /// The apex is **searched for, not assumed**, and that is the difference between this
    /// working and not. Splitting the lines down the middle instead sounds equivalent and is
    /// not: the top and bottom rows of a print are half-covered and land in the cluster or
    /// don't, so the apex is rarely at the median line. One misplaced line puts a kink inside
    /// a half, and the residual that kink contributes grows with the slope — which meant the
    /// check rejected exactly the steep, most unmistakable chevrons and kept only the shallow
    /// ones. Measured on printed rows: assuming the median read 5 of 10 renders, searching
    /// reads 10 of 10.
    private func bends(_ lines: [Double], _ offsets: [Double]) -> Bool {
        // Two points are the fewest that have a slope at all, so that is what each half needs.
        let margin = 2
        guard lines.count >= margin * 2 else { return false }
        for split in margin...(lines.count - margin) {
            let top = fit(lines[..<split], offsets[..<split])
            let bottom = fit(lines[split...], offsets[split...])
            guard top.residual < config.maxShapeResidual,
                  bottom.residual < config.maxShapeResidual,
                  abs(top.slope) >= config.minShapeSlope,
                  abs(bottom.slope) >= config.minShapeSlope,
                  // Equal and opposite. The sign flip is the part a straight line cannot do;
                  // the magnitudes only have to be in the same neighbourhood, because
                  // perspective stretches one half of a row more than the other.
                  top.slope * bottom.slope < 0,
                  abs(abs(top.slope) - abs(bottom.slope))
                      <= config.maxShapeSlopeSpread * max(abs(top.slope), abs(bottom.slope))
            else { continue }
            return true
        }
        return false
    }

    /// One edge's offset against its scan line, fitted by the median of every pairwise slope.
    ///
    /// Theil–Sen rather than least squares, because the lines that need discarding are exactly
    /// the ones least squares weights most. The top and bottom scan lines of a printed row cut
    /// through half-covered, anti-aliased ink, and the local threshold there often finds its
    /// alternation starting at the page margin instead of the first dash — an offset wrong by
    /// the whole width of the row. Least squares spreads one such line across the whole fit,
    /// and the damage grows with the slope, so it rejected precisely the steepest and least
    /// mistakable chevrons. A median ignores them.
    ///
    /// Quadratic in the scan lines crossing one row, which is six to twenty for a sticker on
    /// a rim.
    private func fit(
        _ xs: ArraySlice<Double>,
        _ ys: ArraySlice<Double>
    ) -> (slope: Double, residual: Double) {
        guard xs.count >= 2 else { return (0, .greatestFiniteMagnitude) }
        let x = Array(xs)
        let y = Array(ys)
        var slopes: [Double] = []
        slopes.reserveCapacity(x.count * (x.count - 1) / 2)
        for i in 0..<x.count {
            for j in (i + 1)..<x.count where x[j] != x[i] {
                slopes.append((y[j] - y[i]) / (x[j] - x[i]))
            }
        }
        guard !slopes.isEmpty else { return (0, .greatestFiniteMagnitude) }
        slopes.sort()
        let slope = slopes[slopes.count / 2]
        var intercepts = zip(x, y).map { $1 - slope * $0 }
        intercepts.sort()
        let intercept = intercepts[intercepts.count / 2]
        var residuals = zip(x, y).map { abs($1 - (slope * $0 + intercept)) }
        residuals.sort()
        return (slope, residuals[residuals.count / 2])
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

    func finish(stats: inout BinMarkerFrameStats, from start: CFAbsoluteTime) {
        stats.detectionMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        lastFrameStats = stats
    }
}
