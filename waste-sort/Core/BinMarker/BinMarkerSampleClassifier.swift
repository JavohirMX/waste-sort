import Foundation

/// What one sample along a scan line looks like.
///
/// Kept as raw `Int8` rather than an enum because the scanner writes one per pixel of the
/// working image, every frame, and an array of enums with a payload is not the shape that
/// wants to be.
nonisolated enum BinMarkerCode {
    /// Neither a bar nor the background between bars.
    static let other: Int8 = -1
    /// The strip's background: the gaps between bars, and the quiet zone around them.
    static let gap: Int8 = -2
    /// Anything `>= 0` is a bar, and the value is the ink's index in the palette. Under the
    /// mono style there is only ever ink 0, because black is not an identity.
    static let firstInk: Int8 = 0
}

/// Turns a strided line of pixels into per-sample codes.
///
/// The two styles differ here and nowhere else: everything downstream works on codes, so the
/// scanner, the rhythm reader, and the grouping are written once and shared.
nonisolated enum BinMarkerSampleClassifier {

    /// Reusable buffers. Classification runs on every scan line of every frame, and the mono
    /// path needs three arrays the length of a line — allocating those per line was never
    /// going to survive contact with a 30 Hz camera.
    nonisolated struct Scratch {
        var values: [UInt8] = []
        var windowMin: [UInt8] = []
        var windowMax: [UInt8] = []
        var deque: [Int] = []

        mutating func reserve(_ count: Int) {
            if values.count < count {
                values = [UInt8](repeating: 0, count: count)
                windowMin = [UInt8](repeating: 0, count: count)
                windowMax = [UInt8](repeating: 0, count: count)
                deque = [Int](repeating: 0, count: count)
            }
        }
    }

    /// Reads a line as colored bars on a near-neutral background.
    ///
    /// Only chroma is consulted. A bar in shadow keeps its hue and loses its brightness, so
    /// leaving luma out of the decision is exactly what makes the color style indifferent to
    /// how the room is lit — and it is also why the same code reads a strip whose gaps are
    /// white and one whose gaps are black.
    static func classifyColor(
        chroma: [UInt8],
        start: Int,
        step: Int,
        count: Int,
        inks: [BinMarkerInk],
        config: BinMarkerConfig,
        into codes: inout [Int8]
    ) {
        if codes.count < count { codes = [Int8](repeating: BinMarkerCode.other, count: count) }

        for index in 0..<count {
            let pixel = start + index * step
            let cb = Double(chroma[pixel * 2])
            let cr = Double(chroma[pixel * 2 + 1])
            let dcb = cb - 128
            let dcr = cr - 128
            let magnitude = (dcb * dcb + dcr * dcr).squareRoot()

            if magnitude <= config.maxGapChroma {
                codes[index] = BinMarkerCode.gap
                continue
            }
            guard magnitude >= config.minInkChroma else {
                // Between "clearly nothing" and "clearly an ink" — an edge pixel, or a
                // washed-out print. Calling it either way would only manufacture confidence.
                codes[index] = BinMarkerCode.other
                continue
            }

            var bestIndex = -1
            var bestDistance = Double.greatestFiniteMagnitude
            for (inkIndex, ink) in inks.enumerated() {
                let distance = ink.distance(cb: cb, cr: cr)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = inkIndex
                }
            }
            codes[index] = bestDistance <= config.maxInkDistance
                ? Int8(bestIndex)
                : BinMarkerCode.other
        }
    }

    /// Reads a line as dark bars on a light background, thresholding against a sliding local
    /// window rather than a fixed level.
    ///
    /// Local, because the whole point of the mono style is to work where the color style
    /// cannot, and that is exactly where a global threshold fails: one lamp above one end of
    /// the bins makes any single level wrong somewhere.
    static func classifyMono(
        gray: [UInt8],
        start: Int,
        step: Int,
        count: Int,
        config: BinMarkerConfig,
        into codes: inout [Int8],
        scratch: inout Scratch
    ) {
        if codes.count < count { codes = [Int8](repeating: BinMarkerCode.other, count: count) }
        guard count > 0 else { return }
        scratch.reserve(count)

        for index in 0..<count {
            scratch.values[index] = gray[start + index * step]
        }
        let radius = max(1, min(config.monoWindowRadius, count / 2))
        slidingExtreme(&scratch, count: count, radius: radius, wantMaximum: true)
        slidingExtreme(&scratch, count: count, radius: radius, wantMaximum: false)

        for index in 0..<count {
            let low = Int(scratch.windowMin[index])
            let high = Int(scratch.windowMax[index])
            guard high - low >= config.minMonoContrast else {
                codes[index] = BinMarkerCode.other
                continue
            }
            let midpoint = (low + high) / 2
            codes[index] = Int(scratch.values[index]) < midpoint
                ? BinMarkerCode.firstInk
                : BinMarkerCode.gap
        }
    }

    /// Monotonic-deque sliding min or max over a centred window of `2 * radius + 1`.
    ///
    /// Linear in the line length regardless of the window size, which matters because the
    /// window has to be wide enough to span a bar and its neighbours — the naive version
    /// would put a multiply-by-window-width on every pixel of every frame.
    private static func slidingExtreme(
        _ scratch: inout Scratch,
        count: Int,
        radius: Int,
        wantMaximum: Bool
    ) {
        var head = 0
        var tail = 0

        for index in 0..<(count + radius) {
            if index < count {
                let value = scratch.values[index]
                while tail > head {
                    let candidate = scratch.values[scratch.deque[tail - 1]]
                    let dominated = wantMaximum ? candidate <= value : candidate >= value
                    guard dominated else { break }
                    tail -= 1
                }
                scratch.deque[tail] = index
                tail += 1
            }

            let centre = index - radius
            guard centre >= 0 else { continue }
            while head < tail, scratch.deque[head] < centre - radius { head += 1 }
            let value = scratch.values[scratch.deque[head]]
            if wantMaximum {
                scratch.windowMax[centre] = value
            } else {
                scratch.windowMin[centre] = value
            }
        }
    }
}
