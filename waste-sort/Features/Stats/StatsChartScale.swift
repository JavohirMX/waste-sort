import Foundation

/// Nice Y-axis domain and ticks for Stats charts.
nonisolated enum StatsChartScale {
    struct Axis: Equatable {
        var max: Int
        var step: Int
        var ticks: [Int]
    }

    /// Pads `peak` and rounds onto a 1–2–5 step so charts get about `targetTickCount` labels.
    static func axis(peak: Int, targetTickCount: Int = 5, headroom: Double = 1.1) -> Axis {
        guard peak > 0 else {
            return Axis(max: 10, step: 2, ticks: [0, 2, 4, 6, 8, 10])
        }
        let padded = max(Double(peak) * headroom, 1)
        let rawStep = padded / Double(max(targetTickCount, 2))
        let magnitude = pow(10, floor(log10(rawStep)))
        let residual = rawStep / magnitude
        let niceResidual: Double
        if residual <= 1 {
            niceResidual = 1
        } else if residual <= 2 {
            niceResidual = 2
        } else if residual <= 5 {
            niceResidual = 5
        } else {
            niceResidual = 10
        }
        let step = max(Int((niceResidual * magnitude).rounded()), 1)
        let maxValue = Int((padded / Double(step)).rounded(.up)) * step
        let ticks = stride(from: 0, through: maxValue, by: step).map { $0 }
        return Axis(max: maxValue, step: step, ticks: ticks)
    }

    static func label(_ value: Int) -> String {
        if value == 0 { return "0" }
        if value >= 10_000 || (value >= 1_000 && value.isMultiple(of: 1_000)) {
            let thousands = Double(value) / 1_000
            if thousands == thousands.rounded() {
                return "\(Int(thousands))k"
            }
            return String(format: "%.1fk", thousands)
        }
        return "\(value)"
    }
}
