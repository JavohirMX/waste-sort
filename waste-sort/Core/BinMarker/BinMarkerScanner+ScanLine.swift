import CoreGraphics
import Foundation

// MARK: - One scan line: classify, encode, smooth, and cut candidate strips

extension BinMarkerScanner {
    struct Run {
        var code: Int8
        var start: Int
        var length: Int
    }

    /// A strip as seen by a single scan line.
    struct Segment {
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

    func collectSegments(
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
        case .dashes:
            // Read by `BinMarkerDashScanner`, which is a different shape of problem: a row of
            // equal dashes with nothing encoded in it, rather than a strip to decode.
            return
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
            scan: LineScan(
                image: image,
                start: lineStart,
                step: step,
                row: line,
                orientation: orientation
            ),
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
        scan: LineScan,
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
                scan: scan,
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

    /// Where a candidate strip lives: which scan line, which direction, which pixels.
    private struct LineScan {
        let image: BinMarkerImage
        let start: Int
        let step: Int
        let row: Int
        let orientation: BinMarkerOrientation
    }

    private func makeSegment(
        scan: LineScan,
        firstRun: Int,
        lastRun: Int,
        barCount: Int,
        inkCode: Int8
    ) -> Segment? {
        guard barCount >= 2 else { return nil }

        var barRuns: [Int] = []
        var gapRuns: [Int] = []
        barRuns.reserveCapacity(barCount)
        gapRuns.reserveCapacity(barCount - 1)
        var run = firstRun
        while run <= lastRun {
            if runs[run].code == BinMarkerCode.gap {
                gapRuns.append(run)
            } else {
                barRuns.append(run)
            }
            run += 1
        }

        func measure(_ indices: [Int]) -> [Double] { indices.map { Double(runs[$0].length) } }

        guard var unit = ruler(measure(gapRuns)) else { return nil }

        // Trim an over-wide bar off either end.
        //
        // The bins are in pull-out drawers, so a strip emerges from under a counter edge and
        // the surface just past it is deep shadow. Under the mono style that shadow *is* a
        // black bar as far as a local threshold is concerned, and it joins the strip across
        // the printed margin as a sixth bar — which is not a rhythm we print, so the bin goes
        // unread at the very moment it opens. A bar many times the ruler is not part of the
        // marker, whichever end it sits on.
        let ceiling = config.maxBarUnits * unit
        while barRuns.count > 2, Double(runs[barRuns[0]].length) > ceiling {
            barRuns.removeFirst()
            gapRuns.removeFirst()
        }
        while barRuns.count > 2, let last = barRuns.last, Double(runs[last].length) > ceiling {
            barRuns.removeLast()
            gapRuns.removeLast()
        }
        guard barRuns.count >= 2, let trimmed = ruler(measure(gapRuns)) else { return nil }
        unit = trimmed

        let barWidths = measure(barRuns)
        let patternID = resolvePattern(barWidths: barWidths, unit: unit)
        if patternID == nil {
            // No readable rhythm. Only the color style can go on from here, because only it
            // has a second, independent way to say which bin this is.
            guard config.style.allowsInkOnlyIdentity,
                  config.allowDegradedColor,
                  barRuns.count >= config.minDegradedBars
            else { return nil }
        }

        let firstBar = barRuns[0]
        let lastBar = barRuns[barRuns.count - 1]
        let start = runs[firstBar].start
        let end = runs[lastBar].start + runs[lastBar].length
        var cbSum = 0.0
        var crSum = 0.0
        var samples = 0
        if let chroma = scan.image.chroma {
            // Only the bars that survived trimming: averaging in a shadow that was just
            // rejected would drag the reading the calibration depends on toward neutral.
            for barRun in barRuns {
                for offset in 0..<runs[barRun].length {
                    let pixel = scan.start + (runs[barRun].start + offset) * scan.step
                    cbSum += Double(chroma[pixel * 2])
                    crSum += Double(chroma[pixel * 2 + 1])
                    samples += 1
                }
            }
        }

        return Segment(
            orientation: scan.orientation,
            line: scan.row,
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
}
