import CoreGraphics

/// Cuts one detected item out of a camera frame, small enough to be worth sending to a
/// language model.
///
/// Deliberately CoreGraphics only — no UIKit — so the geometry can be exercised anywhere.
nonisolated enum ItemCropper {
    /// - Parameters:
    ///   - box: the item, normalized 0…1 in image space with the origin top-left — the same
    ///     space `TrackedDetection.displayXywhn` uses, and the space `CGImage` indexes in.
    ///   - padding: fraction of the box added on every side, so the model sees the item in
    ///     context rather than cropped to its own edges.
    ///   - maximumSide: the crop is scaled down to this on its longer side. Bigger crops
    ///     cost time in the model without telling it anything more.
    /// - Returns: nil when there is nothing worth sending — an empty box, or a crop that
    ///   lands off the frame or comes out only a few pixels across.
    static func crop(
        _ image: CGImage,
        to box: CGRect,
        padding: CGFloat,
        maximumSide: Int
    ) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0, box.width > 0, box.height > 0 else { return nil }

        let padded = box.insetBy(dx: -box.width * padding, dy: -box.height * padding)
        let pixels = CGRect(
            x: padded.origin.x * width,
            y: padded.origin.y * height,
            width: padded.width * width,
            height: padded.height * height
        )
        .intersection(CGRect(x: 0, y: 0, width: width, height: height))

        guard !pixels.isNull else { return nil }
        let bounded = pixels.integral
        guard bounded.width >= minimumCropSide,
              bounded.height >= minimumCropSide,
              let cropped = image.cropping(to: bounded)
        else { return nil }

        return downscaled(cropped, maximumSide: maximumSide)
    }

    /// Below this the crop carries no usable detail, whatever the model is asked about it.
    private static let minimumCropSide: CGFloat = 16

    /// Straight CoreGraphics redraw. CGImage to CGImage never flips — the row order follows
    /// the context's memory layout either way — so this is a pure resample.
    ///
    /// Also used to make the debug log's thumbnails, which is why it is not private: keeping
    /// forty full-size crops around to look at would cost tens of megabytes.
    static func downscaled(_ image: CGImage, maximumSide: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard maximumSide > 0, longest > maximumSide else { return image }

        let scale = Double(maximumSide) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else {
            // Sending the full-size crop beats sending nothing.
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
