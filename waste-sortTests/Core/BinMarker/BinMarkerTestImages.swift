import CoreGraphics
import Foundation

@testable import waste_sort

/// Builds synthetic frames for the marker suites.
///
/// Deliberately free of `import Testing` so the same drawing code can be compiled into a
/// plain command-line harness. The detector's whole job is reading pixels, and a test that
/// hand-waves the pixels tests nothing.
nonisolated struct BinMarkerCanvas {
    let width: Int
    let height: Int
    private(set) var gray: [UInt8]
    private(set) var chroma: [UInt8]?

    /// - Parameter includeChroma: pass false to imitate a monochrome camera.
    init(width: Int, height: Int, background: UInt8 = 255, includeChroma: Bool = true) {
        self.width = width
        self.height = height
        self.gray = [UInt8](repeating: background, count: width * height)
        if includeChroma {
            // 128/128 is neutral: white, grey, and black all sit here.
            self.chroma = [UInt8](repeating: 128, count: width * height * 2)
        } else {
            self.chroma = nil
        }
    }

    var image: BinMarkerImage {
        BinMarkerImage(width: width, height: height, gray: gray, chroma: chroma)
    }

    mutating func fill(
        x originX: Int,
        y originY: Int,
        width rectWidth: Int,
        height rectHeight: Int,
        gray value: UInt8,
        cb: UInt8 = 128,
        cr: UInt8 = 128
    ) {
        for y in max(0, originY)..<min(height, originY + rectHeight) {
            for x in max(0, originX)..<min(width, originX + rectWidth) {
                let pixel = y * width + x
                gray[pixel] = value
                if chroma != nil {
                    chroma![pixel * 2] = cb
                    chroma![pixel * 2 + 1] = cr
                }
            }
        }
    }

    /// Draws one strip: `barUnits.count` bars of the given widths, separated by one-unit gaps.
    ///
    /// - Parameters:
    ///   - unit: samples per printed unit, i.e. how big the strip lands in this frame.
    ///   - thickness: the strip's short side, in samples.
    ///   - origin: top-left of the strip's bounding box.
    @discardableResult
    mutating func drawStrip(
        barUnits: [Int],
        unit: Int,
        origin: (x: Int, y: Int),
        thickness: Int,
        orientation: BinMarkerOrientation,
        gray value: UInt8,
        cb: UInt8 = 128,
        cr: UInt8 = 128
    ) -> Int {
        var offset = 0
        for (index, bars) in barUnits.enumerated() {
            let barLength = bars * unit
            switch orientation {
            case .horizontal:
                fill(
                    x: origin.x + offset, y: origin.y,
                    width: barLength, height: thickness,
                    gray: value, cb: cb, cr: cr
                )
            case .vertical:
                fill(
                    x: origin.x, y: origin.y + offset,
                    width: thickness, height: barLength,
                    gray: value, cb: cb, cr: cr
                )
            }
            offset += barLength
            if index < barUnits.count - 1 { offset += unit }
        }
        return offset
    }

    /// Draws a strip printed in one of the palette inks.
    @discardableResult
    mutating func drawInkStrip(
        _ ink: BinMarkerInk,
        barUnits: [Int],
        unit: Int = 6,
        origin: (x: Int, y: Int) = (x: 40, y: 40),
        thickness: Int = 24,
        orientation: BinMarkerOrientation = .horizontal
    ) -> Int {
        drawStrip(
            barUnits: barUnits,
            unit: unit,
            origin: origin,
            thickness: thickness,
            orientation: orientation,
            gray: BinMarkerTestInk.luma(of: ink),
            cb: UInt8(clamping: Int(ink.cb.rounded())),
            cr: UInt8(clamping: Int(ink.cr.rounded()))
        )
    }

    /// Draws a black-on-white strip for the mono style.
    @discardableResult
    mutating func drawMonoStrip(
        barUnits: [Int],
        unit: Int = 6,
        origin: (x: Int, y: Int) = (x: 40, y: 40),
        thickness: Int = 24,
        orientation: BinMarkerOrientation = .horizontal
    ) -> Int {
        drawStrip(
            barUnits: barUnits,
            unit: unit,
            origin: origin,
            thickness: thickness,
            orientation: orientation,
            gray: 24
        )
    }

    /// Dims luma over a region without touching chroma — what a shadow across the bins does.
    mutating func shade(
        x originX: Int,
        y originY: Int,
        width rectWidth: Int,
        height rectHeight: Int,
        scale: Double
    ) {
        for y in max(0, originY)..<min(height, originY + rectHeight) {
            for x in max(0, originX)..<min(width, originX + rectWidth) {
                let pixel = y * width + x
                gray[pixel] = UInt8(clamping: Int(Double(gray[pixel]) * scale))
            }
        }
    }
}

/// Softens a frame the way a real lens and a real shutter do.
///
/// Every crisp-edged synthetic frame flatters a detector, and this one is where the flattery
/// was doing damage: with razor edges nothing ever sat between the classes, so a bar
/// dissolving into its own background was never tested until this existed.
nonisolated enum BinMarkerTestBlur {
    static func apply(_ image: BinMarkerImage, radius: Int) -> BinMarkerImage {
        guard radius > 0 else { return image }
        return BinMarkerImage(
            width: image.width,
            height: image.height,
            gray: box(image.gray, width: image.width, height: image.height,
                      components: 1, radius: radius),
            chroma: image.chroma.map {
                box($0, width: image.width, height: image.height, components: 2, radius: radius)
            }
        )
    }

    private static func box(
        _ source: [UInt8],
        width: Int,
        height: Int,
        components: Int,
        radius: Int
    ) -> [UInt8] {
        var horizontal = source
        for y in 0..<height {
            for x in 0..<width {
                for component in 0..<components {
                    var total = 0
                    for offset in -radius...radius {
                        let sampleX = min(width - 1, max(0, x + offset))
                        total += Int(source[(y * width + sampleX) * components + component])
                    }
                    horizontal[(y * width + x) * components + component] =
                        UInt8(total / (radius * 2 + 1))
                }
            }
        }
        var vertical = horizontal
        for y in 0..<height {
            for x in 0..<width {
                for component in 0..<components {
                    var total = 0
                    for offset in -radius...radius {
                        let sampleY = min(height - 1, max(0, y + offset))
                        total += Int(horizontal[(sampleY * width + x) * components + component])
                    }
                    vertical[(y * width + x) * components + component] =
                        UInt8(total / (radius * 2 + 1))
                }
            }
        }
        return vertical
    }
}

nonisolated enum BinMarkerTestInk {
    static func luma(of ink: BinMarkerInk) -> UInt8 {
        let value = 0.299 * Double(ink.red) + 0.587 * Double(ink.green) + 0.114 * Double(ink.blue)
        return UInt8(clamping: Int(value.rounded()))
    }

    /// An ink that is saturated but far from every palette entry, for rejection tests.
    static let offPalette = BinMarkerInk(
        id: "off-palette", displayName: "Off palette",
        cb: 90, cr: 190,
        red: 220, green: 90, blue: 60
    )

    /// The same ink, weaker: pulled `amount` of the way toward neutral.
    ///
    /// This is what the world does to a printed colour — paper showing through, a tired
    /// cartridge, haze, a camera that under-saturates, blur mixing in the background. The
    /// direction is untouched, which is exactly the property classification must rely on.
    static func faded(_ ink: BinMarkerInk, by amount: Double) -> BinMarkerInk {
        BinMarkerInk(
            id: ink.id,
            displayName: ink.displayName,
            cb: 128 + (ink.cb - 128) * (1 - amount),
            cr: 128 + (ink.cr - 128) * (1 - amount),
            red: ink.red, green: ink.green, blue: ink.blue
        )
    }
}
