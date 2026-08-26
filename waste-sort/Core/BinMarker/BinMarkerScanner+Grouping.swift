import CoreGraphics
import Foundation

// MARK: - Grouping: merge per-line segments into strips

extension BinMarkerScanner {

    /// Merges the per-line segments into strips.
    ///
    /// A strip is many samples tall, so a real one is crossed by several scan lines that all
    /// say the same thing in the same place. One line saying it alone is noise, and this is
    /// where that gets thrown away.
    func group(width: Int, height: Int, timestamp: CFAbsoluteTime) -> [BinMarkerDetection] {
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

            // One strip can leave two clusters with a gap of unscanned lines between them.
            // A blurred marker is brightest through its middle, where the bars merge into a
            // single smear that reads as nothing, while the softer bands along its two long
            // edges still alternate. Same identity, same span, one strip — and reporting it
            // twice would misstate how much of the frame is marker.
            var settled = false
            while !settled {
                settled = true
                var merged: [Cluster] = []
                for cluster in closed {
                    if let index = merged.firstIndex(where: { $0.overlaps(cluster) }) {
                        merged[index].absorb(cluster)
                        settled = false
                    } else {
                        merged.append(cluster)
                    }
                }
                closed = merged
            }

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

        /// The first and last scan line this cluster was seen on.
        var firstLine: Int { segments.map(\.line).min() ?? lastLine }
        /// How many scan lines it spans — the strip's printed thickness, in samples.
        var thickness: Int { lastLine - firstLine + 1 }

        /// Whether another cluster of the same identity covers the same stretch **and lies
        /// alongside it**, and so is the same strip seen through a gap in the scan lines.
        ///
        /// Both halves of that test are load-bearing, and the second one was learned late.
        /// Overlap alone says two clusters are at the same place *along* the strip; it says
        /// nothing about how far apart they are across it. Every bin now carries the same
        /// printed strip, so two bins stacked in the frame produce two clusters with identical
        /// identity and identical span — and merging those would report one strip where there
        /// are two, opening one bin and leaving the other shut.
        ///
        /// The gap this exists to bridge is a strip's own dead middle, where blur smears the
        /// bars into one band that reads as nothing while the softer edges still alternate.
        /// That gap cannot be wider than the strip is thick, which makes the strip its own
        /// yardstick and keeps the rule free of any assumption about scale.
        func overlaps(_ other: Cluster) -> Bool {
            let shared = min(end, other.end) - max(start, other.start)
            guard shared > 0,
                  Double(shared) / Double(min(end - start, other.end - other.start)) >= 0.5
            else { return false }
            let apart = max(firstLine, other.firstLine) - min(lastLine, other.lastLine)
            return apart <= max(thickness, other.thickness)
        }

        mutating func absorb(_ other: Cluster) {
            segments.append(contentsOf: other.segments)
            lastLine = max(lastLine, other.lastLine)
            start = min(start, other.start)
            end = max(end, other.end)
        }
    }
}
