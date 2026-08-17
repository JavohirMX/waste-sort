import AVFoundation
import CoreVideo
import UIKit

/// Encodes an overlay-burned camera clip at inference rate. Drops frames when the encoder is busy.
nonisolated final class AnnotatedVideoWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "waste-sort.annotated-writer")
    private let outputURL: URL
    private let rotation: LivePreviewRotation
    private let mirror: Bool
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startHostTime: CFAbsoluteTime?
    private var isFinished = false

    init(
        outputURL: URL,
        rotation: LivePreviewRotation = .oneEighty,
        mirror: Bool = false
    ) {
        self.outputURL = outputURL
        self.rotation = rotation
        self.mirror = mirror
    }

    func append(image: UIImage, tracks: [TrackedDetection], timestamp: Date) {
        queue.async { [weak self] in
            self?.appendOnQueue(image: image, tracks: tracks, timestamp: timestamp)
        }
    }

    func finish() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                self.finishOnQueue { url in
                    continuation.resume(returning: url)
                }
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self, !self.isFinished else { return }
            self.isFinished = true
            self.input?.markAsFinished()
            self.writer?.cancelWriting()
            self.writer = nil
            self.input = nil
            self.adaptor = nil
            try? FileManager.default.removeItem(at: self.outputURL)
        }
    }

    private func appendOnQueue(image: UIImage, tracks: [TrackedDetection], timestamp: Date) {
        guard !isFinished else { return }
        let composed = DetectionOverlayCompositor.render(
            image: image,
            tracks: tracks,
            timestamp: timestamp,
            rotation: rotation,
            mirror: mirror
        )
        guard let buffer = Self.makePixelBuffer(from: composed) else { return }

        if writer == nil {
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            guard setupWriter(width: width, height: height) else { return }
        }

        guard let writer, writer.status == .writing,
              let input, let adaptor
        else { return }

        guard input.isReadyForMoreMediaData else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if startHostTime == nil {
            startHostTime = now
            writer.startSession(atSourceTime: .zero)
        }
        let elapsed = now - (startHostTime ?? now)
        let time = CMTime(seconds: max(0, elapsed), preferredTimescale: 600)
        adaptor.append(buffer, withPresentationTime: time)
    }

    private func setupWriter(width: Int, height: Int) -> Bool {
        let evenWidth = max(2, width - width % 2)
        let evenHeight = max(2, height - height % 2)
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else {
            return false
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: evenWidth,
            AVVideoHeightKey: evenHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: evenWidth * evenHeight * 4,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return false }
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: evenWidth,
                kCVPixelBufferHeightKey as String: evenHeight,
            ]
        )
        guard writer.startWriting() else { return false }

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        return true
    }

    private func finishOnQueue(completion: @escaping (URL?) -> Void) {
        if isFinished {
            completion(nil)
            return
        }
        isFinished = true

        guard let writer else {
            completion(nil)
            return
        }

        input?.markAsFinished()
        writer.finishWriting { [outputURL] in
            if FileManager.default.fileExists(atPath: outputURL.path) {
                completion(outputURL)
            } else {
                completion(nil)
            }
        }
    }

    private static func makePixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage else { return nil }
        let width = max(2, cgImage.width - cgImage.width % 2)
        let height = max(2, cgImage.height - cgImage.height % 2)

        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
