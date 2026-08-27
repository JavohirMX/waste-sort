import CoreGraphics
import Foundation
import Testing

@testable import waste_sort

@Suite("StatsLayout")
struct StatsLayoutTests {
    /// iPad Pro 11-inch logical points.
    private let iPadPro11Landscape = CGSize(width: 1194, height: 834)
    private let iPadPro11Portrait = CGSize(width: 834, height: 1194)
    /// iPad Air 11-inch logical points — slightly tighter than Pro.
    private let iPadAir11Landscape = CGSize(width: 1180, height: 820)
    private let iPadAir11Portrait = CGSize(width: 820, height: 1180)
    private let iPad13Landscape = CGSize(width: 1366, height: 1024)

    @Test("11-inch landscape uses the split dashboard; portrait stacks")
    func splitLayoutRequiresLandscape() {
        #expect(StatsLayout.usesSplitLayout(size: iPadPro11Landscape, isRegularWidth: true))
        #expect(StatsLayout.usesSplitLayout(size: iPadAir11Landscape, isRegularWidth: true))
        #expect(StatsLayout.usesSplitLayout(size: iPad13Landscape, isRegularWidth: true))

        #expect(!StatsLayout.usesSplitLayout(size: iPadPro11Portrait, isRegularWidth: true))
        #expect(!StatsLayout.usesSplitLayout(size: iPadAir11Portrait, isRegularWidth: true))
        #expect(!StatsLayout.usesSplitLayout(size: iPadPro11Landscape, isRegularWidth: false))
    }

    @Test("11-inch landscape half-card bars fit in the remaining chart width")
    func elevenInchHalfCardBarsFit() {
        // Air 11 is the tighter landscape: pageInset 28×2, split gap 20, card pad 28×2,
        // summary 150, summary gap 20, y-label 28 → chart width 298.
        let chartWidth = Self.halfCardChartWidth(
            screenWidth: iPadAir11Landscape.width,
            summaryWidth: StatsLayout.wideSummaryWidth
        )
        let stack = StatsLayout.barStackWidth(availableWidth: chartWidth, binCount: 3, isWide: true)
        #expect(stack <= chartWidth + 0.5)
        #expect(
            StatsLayout.barWidth(availableWidth: chartWidth, binCount: 3, isWide: true)
                >= StatsLayout.wideBarFloor
        )
    }

    @Test("shrinking the summary column on a narrow card still fits")
    func narrowCardSummaryAndBarsFit() {
        let inner = Self.halfCardInnerWidth(screenWidth: iPadAir11Landscape.width)
        let summary = StatsLayout.generatedSummaryWidth(isWide: true, cardInnerWidth: inner)
        #expect(summary == StatsLayout.compactSummaryWidth)

        let chartWidth = Self.halfCardChartWidth(
            screenWidth: iPadAir11Landscape.width,
            summaryWidth: summary
        )
        let stack = StatsLayout.barStackWidth(availableWidth: chartWidth, binCount: 3, isWide: true)
        #expect(stack <= chartWidth + 0.5)
    }

    @Test("13-inch split cards keep the wide summary column")
    func thirteenInchKeepsWideSummary() {
        let inner = Self.halfCardInnerWidth(screenWidth: iPad13Landscape.width)
        #expect(
            StatsLayout.generatedSummaryWidth(isWide: true, cardInnerWidth: inner)
                == StatsLayout.wideSummaryWidth
        )
        #expect(StatsLayout.barWidth(availableWidth: 400, binCount: 3, isWide: true) == StatsLayout.wideBarCap)
    }

    @Test("bars never overflow even when the chart is extremely narrow")
    func crampedBarsDoNotOverflow() {
        let chartWidth: CGFloat = 80
        let stack = StatsLayout.barStackWidth(availableWidth: chartWidth, binCount: 3, isWide: true)
        #expect(stack <= chartWidth + 0.5)
    }

    @Test("split body metrics fill leftover height without overflowing")
    func splitBodyFillsLeftoverHeight() {
        let size = CGSize(width: 1124, height: 574)
        let metrics = StatsLayout.splitBodyMetrics(size: size)
        #expect(metrics.topHeight + metrics.gap + metrics.bottomHeight == size.height)
        #expect(metrics.columnGap == 20)
        #expect(metrics.gap == 14)
        #expect(metrics.usesCompactChrome)

        let cramped = StatsLayout.splitBodyMetrics(size: CGSize(width: 1_000, height: 500))
        #expect(cramped.gap == 14)
        #expect(cramped.columnGap == 14)
        #expect(cramped.topHeight + cramped.gap + cramped.bottomHeight == 500)

        let roomy = StatsLayout.splitBodyMetrics(size: CGSize(width: 1_300, height: 800))
        #expect(!roomy.usesCompactChrome)
        #expect(roomy.gap == 22)
    }

    @Test("compact Thrown-into chrome is shorter than the 13-inch row chrome")
    func compactThrownIntoChromeIsTighter() {
        let full = StatsLayout.thrownIntoMetrics(isWide: true, compact: false)
        let compact = StatsLayout.thrownIntoMetrics(isWide: true, compact: true)
        #expect(compact.verticalPadding < full.verticalPadding)
        #expect(compact.rowSpacing < full.rowSpacing)
        #expect(compact.cardPadding < full.cardPadding)
        #expect(compact.nameSize < full.nameSize)
    }

    private static func halfCardInnerWidth(screenWidth: CGFloat) -> CGFloat {
        let pageInset: CGFloat = 28
        let splitGap: CGFloat = 20
        let cardPadding: CGFloat = 28
        let cardOuter = (screenWidth - pageInset * 2 - splitGap) / 2
        return cardOuter - cardPadding * 2
    }

    private static func halfCardChartWidth(screenWidth: CGFloat, summaryWidth: CGFloat) -> CGFloat {
        let summaryGap: CGFloat = 20
        let yLabelWidth: CGFloat = 28
        return halfCardInnerWidth(screenWidth: screenWidth) - summaryWidth - summaryGap - yLabelWidth
    }
}
