//
//  ResultStatusPresentationTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("ResultStatusPresentation")
@MainActor
struct ResultStatusPresentationTests {
    private func presentation(_ tier: StatusBarTier) -> ResultStatusPresentation {
        ResultStatusPresentation(tier: tier)
    }

    @Test("The widest tier draws everything")
    func regularDrawsEverything() {
        let result = presentation(.regular)
        #expect(result.showsControlTitles)
        #expect(result.modeSwitcherIsSegmented)
        #expect(result.showsEdgePageButtons)
        #expect(result.pageSizeIsInline)
    }

    @Test("Titles go before any control does")
    func titlesAreGivenUpFirst() {
        let compact = presentation(.compact)
        #expect(!compact.showsControlTitles)
        #expect(compact.pageSizeIsInline)
    }

    @Test("The narrowest tier keeps rows-per-page reachable rather than dropping it")
    func narrowFoldsPageSizeInsteadOfDroppingIt() {
        #expect(!presentation(.narrow).pageSizeIsInline)
    }

    @Test("The narrowest tier swaps the segmented switcher for a pull-down")
    func narrowUsesAMenuSwitcher() {
        #expect(!presentation(.narrow).modeSwitcherIsSegmented)
    }

    /// Every tier below the widest gives something up, or the ladder has a rung that buys nothing
    /// and `ViewThatFits` would pick the same row twice.
    @Test("Each tier is strictly cheaper than the one above it")
    func everyTierGivesSomethingUp() {
        let ordered = [presentation(.regular), presentation(.compact), presentation(.narrow)]
        for (wider, narrower) in zip(ordered, ordered.dropFirst()) {
            #expect(cost(narrower) < cost(wider))
        }
    }

    /// How many width-bearing affordances a tier draws. Not a measurement, only an ordering.
    private func cost(_ presentation: ResultStatusPresentation) -> Int {
        var total = 0
        if presentation.showsControlTitles { total += 1 }
        if presentation.modeSwitcherIsSegmented { total += 1 }
        if presentation.showsEdgePageButtons { total += 1 }
        if presentation.pageSizeIsInline { total += 1 }
        return total
    }

    /// The narrowest tier changes how controls are drawn and which one carries rows-per-page. It
    /// removes nothing, because a `.popover` anchored to a button that has left the view tree cannot
    /// present, which would leave the matching menu item inert.
    @Test("The narrowest tier redraws controls rather than removing any")
    func narrowestTierRemovesNothing() {
        let narrow = presentation(.narrow)
        #expect(!narrow.showsEdgePageButtons)
        #expect(!narrow.pageSizeIsInline)
        #expect(!narrow.modeSwitcherIsSegmented)
        #expect(!narrow.showsControlTitles)
    }

    @Test("The mode pull-down is capped so a long locale cannot widen the narrowest tier")
    func modeMenuIsCapped() {
        #expect(StatusBarLayoutMetrics.modeMenuMaximumWidth > 0)
        #expect(StatusBarLayoutMetrics.modeMenuMaximumWidth < MainSplitViewController.defaultDetailMinThickness)
    }

    /// The readout reports a constant ideal width on purpose: `ViewThatFits` chooses on a candidate's
    /// ideal size, so reading it off the sentence would let a wordy driver message drop the bar a
    /// tier by itself.
    @Test("The readout's ideal width leaves room for the clusters beside it")
    func readoutAllowanceLeavesRoomForTheClusters() {
        let usable = MainSplitViewController.defaultDetailMinThickness
            - StatusBarChrome.horizontalPadding * 2
        #expect(StatusBarLayoutMetrics.readoutIdealWidth < usable)
    }
}
