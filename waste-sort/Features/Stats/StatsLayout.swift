import CoreGraphics

/// Size-dependent Stats dashboard metrics. Keep view files free of the arithmetic
/// that used to overflow 11-inch iPads in landscape.
nonisolated enum StatsLayout {
    static let splitMinWidth: CGFloat = 700

    static let wideBarCap: CGFloat = 96
    static let compactBarCap: CGFloat = 68
    static let wideBarFloor: CGFloat = 56
    static let compactBarFloor: CGFloat = 44
    static let wideBarSpacing: CGFloat = 24
    static let compactBarSpacing: CGFloat = 16

    /// Half-width 11-inch cards sit under this; 13-inch split cards sit above.
    static let narrowCardInnerWidth: CGFloat = 560
    static let wideSummaryWidth: CGFloat = 150
    static let compactSummaryWidth: CGFloat = 120

    /// Split only when there is genuinely landscape room for two columns.
    /// A portrait iPad is wide enough in points (`>= 700`) but too narrow per card.
    static func usesSplitLayout(size: CGSize, isRegularWidth: Bool) -> Bool {
        isRegularWidth && size.width >= splitMinWidth && size.width > size.height
    }

    static func barSpacing(isWide: Bool) -> CGFloat {
        isWide ? wideBarSpacing : compactBarSpacing
    }

    /// Fits `binCount` equal bars plus gaps into `availableWidth`.
    /// Caps at the design width; shrinks when the card is too narrow to hold that cap.
    static func barWidth(availableWidth: CGFloat, binCount: Int, isWide: Bool) -> CGFloat {
        let cap = isWide ? wideBarCap : compactBarCap
        let minimum = isWide ? wideBarFloor : compactBarFloor
        let count = max(binCount, 1)
        let gaps = CGFloat(count - 1) * barSpacing(isWide: isWide)
        let fitted = max((availableWidth - gaps) / CGFloat(count), 0)
        if fitted < minimum {
            return fitted
        }
        return min(cap, fitted)
    }

    static func barStackWidth(availableWidth: CGFloat, binCount: Int, isWide: Bool) -> CGFloat {
        let count = max(binCount, 0)
        guard count > 0 else { return 0 }
        let width = barWidth(availableWidth: availableWidth, binCount: count, isWide: isWide)
        return CGFloat(count) * width + CGFloat(count - 1) * barSpacing(isWide: isWide)
    }

    static func generatedSummaryWidth(isWide: Bool, cardInnerWidth: CGFloat) -> CGFloat {
        guard isWide else { return compactSummaryWidth }
        return cardInnerWidth < narrowCardInnerWidth ? compactSummaryWidth : wideSummaryWidth
    }

    /// Card split inside leftover space below the Stats header + period picker.
    struct SplitBodyMetrics: Equatable {
        var gap: CGFloat
        var columnGap: CGFloat
        var topHeight: CGFloat
        var bottomHeight: CGFloat
        /// 11-inch leftover height cannot host the 13-inch Thrown-into row chrome.
        var usesCompactChrome: Bool
    }

    static func splitBodyMetrics(size: CGSize) -> SplitBodyMetrics {
        let compact = size.height < 640
        let gap: CGFloat = compact ? 14 : 22
        let topRatio: CGFloat = compact ? 0.52 : 0.48
        let topHeight = size.height * topRatio
        return SplitBodyMetrics(
            gap: gap,
            columnGap: size.width < 1_100 ? 14 : 20,
            topHeight: topHeight,
            bottomHeight: max(size.height - topHeight - gap, 0),
            usesCompactChrome: compact
        )
    }

    struct ThrownIntoMetrics: Equatable {
        var sectionSpacing: CGFloat
        var rowSpacing: CGFloat
        var titleSize: CGFloat
        var nameSize: CGFloat
        var countsSize: CGFloat
        var percentSize: CGFloat
        var iconSize: CGFloat
        var iconFrame: CGFloat
        var hStackSpacing: CGFloat
        var labelBarSpacing: CGFloat
        var horizontalPadding: CGFloat
        var verticalPadding: CGFloat
        var barHeight: CGFloat
        var cardPadding: CGFloat
    }

    static func thrownIntoMetrics(isWide: Bool, compact: Bool) -> ThrownIntoMetrics {
        if !isWide {
            return ThrownIntoMetrics(
                sectionSpacing: 12,
                rowSpacing: 8,
                titleSize: 17,
                nameSize: 15,
                countsSize: 12,
                percentSize: 18,
                iconSize: 18,
                iconFrame: 22,
                hStackSpacing: 10,
                labelBarSpacing: 8,
                horizontalPadding: 14,
                verticalPadding: 10,
                barHeight: 8,
                cardPadding: 28
            )
        }
        if compact {
            return ThrownIntoMetrics(
                sectionSpacing: 8,
                rowSpacing: 6,
                titleSize: 17,
                nameSize: 17,
                countsSize: 13,
                percentSize: 18,
                iconSize: 18,
                iconFrame: 22,
                hStackSpacing: 8,
                labelBarSpacing: 6,
                horizontalPadding: 14,
                verticalPadding: 8,
                barHeight: 8,
                cardPadding: 18
            )
        }
        return ThrownIntoMetrics(
            sectionSpacing: 16,
            rowSpacing: 12,
            titleSize: 19,
            nameSize: 22,
            countsSize: 16,
            percentSize: 22,
            iconSize: 22,
            iconFrame: 28,
            hStackSpacing: 12,
            labelBarSpacing: 10,
            horizontalPadding: 20,
            verticalPadding: 12,
            barHeight: 10,
            cardPadding: 28
        )
    }
}
