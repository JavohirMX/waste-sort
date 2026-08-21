import CoreGraphics

/// How much fine detail an image actually carries.
///
/// Used to pick which frame of an item to show the model. A person carrying something past a
/// camera produces mostly smeared frames and a few clean ones, and which one gets sent is
/// otherwise pure chance — the model is only as good as the picture it is handed.
nonisolated enum ImageSharpness {
    /// Variance of the Laplacian over a fixed-size grayscale copy. Higher is sharper.
    ///
    /// The fixed sample size matters: scores are only ever compared between crops of the
    /// *same* item taken moments apart, and resampling everything to one size stops a crop
    /// that merely grew from beating one that is genuinely sharper.
    ///
    /// - Returns: 0 for anything that cannot be measured, which sorts last.
    static func score(_ image: CGImage, sampleSide: Int = 96) -> Double {
        guard sampleSide >= 3, let pixels = grayscale(image, side: sampleSide) else { return 0 }

        var sum = 0.0
        var sumOfSquares = 0.0
        var count = 0.0

        // Four-neighbour Laplacian over the interior; the border has no neighbourhood.
        for y in 1..<(sampleSide - 1) {
            let row = y * sampleSide
            for x in 1..<(sampleSide - 1) {
                let centre = Double(pixels[row + x])
                let edge =
                    4 * centre
                    - Double(pixels[row + x - 1])
                    - Double(pixels[row + x + 1])
                    - Double(pixels[row - sampleSide + x])
                    - Double(pixels[row + sampleSide + x])
                let normalized = edge / 255.0
                sum += normalized
                sumOfSquares += normalized * normalized
                count += 1
            }
        }

        guard count > 0 else { return 0 }
        let mean = sum / count
        return max(0, sumOfSquares / count - mean * mean)
    }

    private static func grayscale(_ image: CGImage, side: Int) -> [UInt8]? {
        guard let space = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let context = CGContext(
                  data: nil,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: side,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { return nil }

        // Stretched to a square on purpose: aspect distortion does not change how much edge
        // energy is present, and a fixed buffer keeps the arithmetic simple. The resample
        // has to average rather than pick nearest — nearest-neighbour on fine texture
        // aliases, and a sharp image would score as a flat one depending on phase.
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: side * side)
        return Array(UnsafeBufferPointer(start: buffer, count: side * side))
    }
}
