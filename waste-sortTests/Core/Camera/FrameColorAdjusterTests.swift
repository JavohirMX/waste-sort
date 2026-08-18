import CoreVideo
import Testing
@testable import waste_sort

struct FrameColorAdjusterTests {
    @Test func identityIsSkipped() {
        #expect(FrameColorControls.identity.isIdentity)
        #expect(FrameColorControls(brightness: 0, contrast: 1, saturation: 1).isIdentity)
        #expect(!FrameColorControls(brightness: 0.1, contrast: 1, saturation: 1).isIdentity)
        #expect(!FrameColorControls(brightness: 0, contrast: 1.1, saturation: 1).isIdentity)
        #expect(!FrameColorControls(brightness: 0, contrast: 1, saturation: 0.5).isIdentity)
    }

    @Test func identityProcessDoesNotWritePixels() {
        let buffer = makeGrayBuffer(gray: 80)
        let before = meanGray(buffer)
        let didProcess = FrameColorAdjuster.processInPlace(buffer, controls: .identity)
        #expect(!didProcess)
        #expect(meanGray(buffer) == before)
    }

    @Test func clampHelpersRespectRanges() {
        #expect(FrameColorAdjuster.clampedBrightness(0) == 0)
        #expect(FrameColorAdjuster.clampedBrightness(0.8) == 0.5)
        #expect(FrameColorAdjuster.clampedBrightness(-0.8) == -0.5)
        #expect(FrameColorAdjuster.clampedContrast(1) == 1)
        #expect(FrameColorAdjuster.clampedContrast(0) == 0.5)
        #expect(FrameColorAdjuster.clampedContrast(9) == 1.5)
        #expect(FrameColorAdjuster.clampedSaturation(1) == 1)
        #expect(FrameColorAdjuster.clampedSaturation(-1) == 0)
        #expect(FrameColorAdjuster.clampedSaturation(9) == 2)
    }

    @Test func brightnessRaisesMeanLuminanceOnGrayImage() {
        let buffer = makeGrayBuffer(gray: 80)
        let before = meanGray(buffer)
        let didProcess = FrameColorAdjuster.processInPlace(
            buffer,
            controls: FrameColorControls(brightness: 0.25, contrast: 1, saturation: 1)
        )
        #expect(didProcess)
        #expect(meanGray(buffer) > before + 8)
    }
}

private func makeGrayBuffer(gray: UInt8, width: Int = 16, height: Int = 16) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ] as CFDictionary,
        &buffer
    )
    precondition(status == kCVReturnSuccess && buffer != nil, "failed to create pixel buffer")
    let pixelBuffer = buffer!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        let row = base.advanced(by: y * bytesPerRow)
        for x in 0..<width {
            let pixel = row.advanced(by: x * 4)
            pixel[0] = gray
            pixel[1] = gray
            pixel[2] = gray
            pixel[3] = 255
        }
    }
    return pixelBuffer
}

private func meanGray(_ buffer: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    var sum = 0.0
    for y in 0..<height {
        let row = base.advanced(by: y * bytesPerRow)
        for x in 0..<width {
            let pixel = row.advanced(by: x * 4)
            sum += (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 3.0
        }
    }
    return sum / Double(width * height)
}
