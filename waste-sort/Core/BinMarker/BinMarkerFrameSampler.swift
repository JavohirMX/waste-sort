import CoreVideo
import Foundation

/// Reduces a camera frame to the luma-and-chroma grid the scanner reads.
///
/// The grid is the chroma plane's, not the frame's. A 4:2:0 camera hands over chroma at half
/// size already, so meeting it there costs a quarter of the work and loses nothing that
/// matters: the bars are centimetres wide, and it is their *ratios* that carry the identity.
///
/// Called from the camera queue, before `FrameColorAdjuster` rewrites the buffer in place.
/// That ordering is the whole reason the color style needs no exposure tuning — it reads the
/// sensor's chroma, not the preview's.
nonisolated final class BinMarkerFrameSampler {
    /// Decimate further if the chroma plane is still wider than this. 4K would otherwise put
    /// four times the samples through the scan for bars that were already legible at 1080p.
    var maximumWidth: Int = 960

    private var gray: [UInt8] = []
    private var chroma: [UInt8] = []
    private var width = 0
    private var height = 0
    private var carriesChroma = false

    init() {}

    /// Fills the internal buffers from `pixelBuffer`.
    ///
    /// - Returns: false when the format is one we cannot read, which the caller must surface
    ///   rather than swallow: silence here would present as three permanently shut bins.
    @discardableResult
    func sample(_ pixelBuffer: CVPixelBuffer) -> Bool {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard sourceWidth > 1, sourceHeight > 1 else { return false }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return false
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return sampleBiplanar(pixelBuffer, width: sourceWidth, height: sourceHeight)
        case kCVPixelFormatType_32BGRA:
            return sampleBGRA(pixelBuffer, width: sourceWidth, height: sourceHeight)
        case kCVPixelFormatType_OneComponent8:
            return sampleGrayscale(pixelBuffer, width: sourceWidth, height: sourceHeight)
        default:
            return false
        }
    }

    /// The most recent sample. Copying the buffers out is what makes this value safe to hand
    /// to the scanner while the next frame is already being written; at these sizes the copy
    /// costs a fraction of the scan it feeds.
    var image: BinMarkerImage {
        BinMarkerImage(
            width: width,
            height: height,
            gray: gray,
            chroma: carriesChroma ? chroma : nil
        )
    }

    // MARK: - Formats

    /// 4:2:0 biplanar — the format the capture session hands over by default.
    ///
    /// Video-range chroma spans 16…240 rather than 0…255, so a saturated ink lands about 12%
    /// nearer neutral than its nominal value. The palette sits far enough apart that this
    /// changes nothing, and calibration against the real print absorbs the rest.
    private func sampleBiplanar(_ buffer: CVPixelBuffer, width sourceWidth: Int, height sourceHeight: Int) -> Bool {
        guard CVPixelBufferGetPlaneCount(buffer) >= 2,
              let lumaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        else { return false }

        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let step = decimation(for: chromaWidth)
        guard prepare(width: chromaWidth / step, height: chromaHeight / step, chroma: true) else {
            return false
        }

        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let luma = lumaPlane.assumingMemoryBound(to: UInt8.self)
        let colors = chromaPlane.assumingMemoryBound(to: UInt8.self)
        // Luma is full size; two chroma samples along equals four luma pixels along.
        let lumaStep = step * 2

        for y in 0..<height {
            let chromaBase = (y * step) * chromaRow
            let lumaBase = min(y * lumaStep, sourceHeight - 1) * lumaRow
            for x in 0..<width {
                let source = chromaBase + (x * step) * 2
                let destination = y * width + x
                chroma[destination * 2] = colors[source]
                chroma[destination * 2 + 1] = colors[source + 1]
                gray[destination] = luma[lumaBase + min(x * lumaStep, sourceWidth - 1)]
            }
        }
        return true
    }

    /// BGRA — what some USB cameras negotiate. Converted a pixel at a time, but only every
    /// `step`-th one in each direction, so the loop touches a small fraction of the frame.
    private func sampleBGRA(_ buffer: CVPixelBuffer, width sourceWidth: Int, height sourceHeight: Int) -> Bool {
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let step = decimation(for: sourceWidth / 2) * 2
        guard prepare(width: sourceWidth / step, height: sourceHeight / step, chroma: true) else {
            return false
        }

        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            let row = (y * step) * rowBytes
            for x in 0..<width {
                let source = row + (x * step) * 4
                let blue = Double(pixels[source])
                let green = Double(pixels[source + 1])
                let red = Double(pixels[source + 2])
                let luma = 0.299 * red + 0.587 * green + 0.114 * blue
                let destination = y * width + x
                gray[destination] = UInt8(clamping: Int(luma))
                chroma[destination * 2] = UInt8(clamping: Int(0.564 * (blue - luma) + 128))
                chroma[destination * 2 + 1] = UInt8(clamping: Int(0.713 * (red - luma) + 128))
            }
        }
        return true
    }

    /// A monochrome sensor. Only the mono style can work from this, and the scanner says so.
    private func sampleGrayscale(_ buffer: CVPixelBuffer, width sourceWidth: Int, height sourceHeight: Int) -> Bool {
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let step = decimation(for: sourceWidth / 2) * 2
        guard prepare(width: sourceWidth / step, height: sourceHeight / step, chroma: false) else {
            return false
        }

        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = (y * step) * rowBytes
            for x in 0..<width {
                gray[y * width + x] = pixels[row + x * step]
            }
        }
        return true
    }

    // MARK: - Buffers

    private func decimation(for chromaWidth: Int) -> Int {
        guard maximumWidth > 0, chromaWidth > maximumWidth else { return 1 }
        return max(1, chromaWidth / maximumWidth)
    }

    private func prepare(width newWidth: Int, height newHeight: Int, chroma wantsChroma: Bool) -> Bool {
        guard newWidth > 1, newHeight > 1 else { return false }
        width = newWidth
        height = newHeight
        carriesChroma = wantsChroma
        let samples = newWidth * newHeight
        if gray.count != samples { gray = [UInt8](repeating: 0, count: samples) }
        if wantsChroma, chroma.count != samples * 2 {
            chroma = [UInt8](repeating: 128, count: samples * 2)
        }
        return true
    }
}
