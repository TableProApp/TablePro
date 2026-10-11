//
//  WorkspaceRailScrollGeometryTests.swift
//  TableProTests
//
//  The strip used to come to rest wherever a scroll left it, which cut the glyph off the entry at
//  the top of the viewport and was reported as a drawing bug (#2452). These pin the offsets it is
//  allowed to rest on. A source list puts its first row 10pt down the document, which is what the
//  strip ships with; a top of zero is a plain table.
//

import AppKit
import Foundation
@testable import TablePro
import Testing

struct WorkspaceRailScrollGeometryTests {
    private static let sourceListTop: CGFloat = 10

    private func geometry(
        rows: Int,
        height: CGFloat = 60,
        top: CGFloat = 0,
        viewport: CGFloat
    ) -> WorkspaceRailScrollGeometry {
        WorkspaceRailScrollGeometry(
            rowCount: rows, rowHeight: height, firstRowTop: top, viewportHeight: viewport
        )
    }

    /// An origin is a tile edge when it is the very top, or a row's top sits exactly on it.
    private func isTileEdge(_ origin: CGFloat, in geometry: WorkspaceRailScrollGeometry) -> Bool {
        guard origin > 0.001 else { return true }
        let offset = origin - geometry.firstRowTop
        let remainder = offset.truncatingRemainder(dividingBy: geometry.rowHeight)
        return offset >= -0.001 && (abs(remainder) < 0.001 || abs(remainder - geometry.rowHeight) < 0.001)
    }

    @Test("A strip whose entries fit cannot rest anywhere but the top")
    func fittingStripRestsAtTheTop() {
        let fitting = geometry(rows: 6, viewport: 448)
        #expect(fitting.maximumRestingOrigin == 0)
        #expect(fitting.settledOrigin(proposed: 137, selectedRow: nil) == 0)
    }

    @Test("The furthest resting offset keeps the last entry whole")
    func maximumRestingOriginKeepsTheLastEntryWhole() {
        let strip = geometry(rows: 12, viewport: 448)
        #expect(strip.maximumRestingOrigin == 300)
        #expect(strip.maximumRestingOrigin + 448 >= strip.top(ofRow: 12))
        #expect(isTileEdge(strip.maximumRestingOrigin, in: strip))
    }

    /// The case the source list's padding broke: a resting offset counted in whole rows from the
    /// document's top stopped 10pt short of the last tile.
    @Test("In a source list the furthest resting offset still keeps the last entry whole")
    func sourceListMaximumKeepsTheLastEntryWhole() {
        for viewport in stride(from: CGFloat(200), through: 900, by: 1) {
            let strip = geometry(rows: 12, top: Self.sourceListTop, viewport: viewport)
            let maximum = strip.maximumRestingOrigin
            guard maximum > 0 else { continue }
            #expect(maximum + viewport >= strip.top(ofRow: 12), "last tile cut at viewport \(viewport)")
            #expect(isTileEdge(maximum, in: strip), "maximum \(maximum) mid-tile at viewport \(viewport)")
        }
    }

    @Test("The bottom inset is what brings the furthest offset within reach")
    func bottomInsetMakesTheLastOffsetReachable() {
        let strip = geometry(rows: 12, top: Self.sourceListTop, viewport: 448)
        let documentHeight = Self.sourceListTop + 12 * 60 + Self.sourceListTop
        let inset = strip.bottomInset(documentHeight: documentHeight)
        #expect(documentHeight - 448 < strip.maximumRestingOrigin)
        #expect(documentHeight - 448 + inset == strip.maximumRestingOrigin)
    }

    @Test("A strip that needs no scrolling asks for no inset")
    func fittingStripNeedsNoInset() {
        #expect(geometry(rows: 4, viewport: 448).bottomInset(documentHeight: 448) == 0)
    }

    @Test("Every settled offset lands on a tile edge, at every layout and both table styles")
    func everySettledOffsetLandsOnATileEdge() {
        for layout in [WorkspaceRailMetrics.small, WorkspaceRailMetrics.medium, WorkspaceRailMetrics.large] {
            let height = CGFloat(Int(layout.iconSize) * 2 + 20)
            for top in [CGFloat(0), Self.sourceListTop] {
                for viewport in stride(from: CGFloat(200), through: 900, by: 37) {
                    let strip = geometry(rows: 20, height: height, top: top, viewport: viewport)
                    let maximum = strip.maximumRestingOrigin
                    for proposed in stride(from: CGFloat(-40), through: maximum + 200, by: 11) {
                        let settled = strip.settledOrigin(proposed: proposed, selectedRow: nil)
                        #expect(settled >= 0)
                        #expect(settled <= maximum)
                        #expect(isTileEdge(settled, in: strip), "settled \(settled) is mid-tile")
                    }
                }
            }
        }
    }

    /// Snapping to whole rows from the document's top used to leave the bottom 10pt of the previous
    /// tile at the top of the strip, a band of accent fill when that tile was selected.
    @Test("A settled source-list strip shows no sliver of the tile above")
    func settledSourceListShowsNoSliver() {
        let strip = geometry(rows: 12, top: Self.sourceListTop, viewport: 300)
        #expect(strip.settledOrigin(proposed: 183, selectedRow: nil) == 190)
        #expect(strip.settledOrigin(proposed: 120, selectedRow: nil) == 130)
        #expect(strip.settledOrigin(proposed: 4, selectedRow: nil) == 0)
    }

    @Test("Settling never rounds up past the furthest offset")
    func settlingNeverOvershootsTheMaximum() {
        let strip = geometry(rows: 12, viewport: 448)
        #expect(strip.settledOrigin(proposed: strip.maximumRestingOrigin + 500, selectedRow: nil)
            == strip.maximumRestingOrigin)
        #expect(strip.settledOrigin(proposed: 289, selectedRow: nil) == strip.maximumRestingOrigin)
    }

    @Test("An entry already whole and on screen is left alone")
    func visibleEntryIsNotRevealed() {
        #expect(geometry(rows: 12, viewport: 448).revealOrigin(row: 2, currentOrigin: 0) == nil)
        #expect(geometry(rows: 12, top: Self.sourceListTop, viewport: 448)
            .revealOrigin(row: 2, currentOrigin: 0) == nil)
    }

    @Test("An entry above the viewport is revealed at its own top edge")
    func entryAboveIsRevealedAtItsTop() {
        #expect(geometry(rows: 12, viewport: 448).revealOrigin(row: 1, currentOrigin: 300) == 60)
        #expect(geometry(rows: 12, top: Self.sourceListTop, viewport: 448)
            .revealOrigin(row: 1, currentOrigin: 310) == 70)
    }

    @Test("The first entry is revealed with the strip back at its very top")
    func firstEntryIsRevealedAtTheTop() {
        #expect(geometry(rows: 12, top: Self.sourceListTop, viewport: 448)
            .revealOrigin(row: 0, currentOrigin: 190) == 0)
    }

    @Test("An entry below the viewport is revealed whole, on a tile edge")
    func entryBelowIsRevealedWholeOnATileEdge() {
        for top in [CGFloat(0), Self.sourceListTop] {
            let strip = geometry(rows: 12, top: top, viewport: 448)
            let origin = strip.revealOrigin(row: 9, currentOrigin: 0) ?? -1
            #expect(origin >= 0)
            #expect(isTileEdge(origin, in: strip))
            #expect(origin <= strip.top(ofRow: 9))
            #expect(origin + 448 >= strip.top(ofRow: 9) + 60)
        }
    }

    @Test("Revealing the last entry lands exactly on the furthest resting offset")
    func lastEntryIsReachableWhole() {
        for top in [CGFloat(0), Self.sourceListTop] {
            for viewport in stride(from: CGFloat(200), through: 900, by: 23) {
                let strip = geometry(rows: 20, height: 66, top: top, viewport: viewport)
                let origin = strip.revealOrigin(row: 19, currentOrigin: 0)
                #expect(origin == strip.maximumRestingOrigin)
                #expect(strip.maximumRestingOrigin + viewport >= strip.top(ofRow: 20))
            }
        }
    }

    @Test("A viewport that ends inside the padding under the last entry still holds them all")
    func viewportEndingInTrailingPaddingCountsAsFitting() {
        let viewport = Self.sourceListTop + 8 * 60 + 5
        let strip = geometry(rows: 8, top: Self.sourceListTop, viewport: viewport)
        #expect(strip.maximumRestingOrigin == 0)
        #expect(strip.bottomInset(documentHeight: viewport) == 0)
    }

    /// Only the padding above the first tile is in the way, so hiding it shows every tile whole
    /// without scrolling a whole row.
    @Test("A viewport just short of the rows rests with the first tile at the top")
    func viewportJustShortRestsOnTheFirstTile() {
        let strip = geometry(rows: 8, top: Self.sourceListTop, viewport: 8 * 60 + 5)
        #expect(strip.maximumRestingOrigin == Self.sourceListTop)
        #expect(strip.settledOrigin(proposed: 7, selectedRow: nil) == Self.sourceListTop)
    }

    @Test("Settling does not cut an entry the highlight was showing whole")
    func settlingKeepsAWholeHighlightWhole() {
        for top in [CGFloat(0), Self.sourceListTop] {
            let strip = geometry(rows: 12, top: top, viewport: 469)
            let settled = strip.settledOrigin(proposed: 89 + top, selectedRow: 8)
            #expect(isTileEdge(settled, in: strip))
            #expect(settled <= strip.top(ofRow: 8))
            #expect(settled + 469 >= strip.top(ofRow: 8) + 60)
        }
    }

    @Test("Scrolling away from the highlighted entry settles where the scroll ended")
    func settlingDoesNotTetherToAnOffScreenHighlight() {
        let strip = geometry(rows: 12, viewport: 430)
        let settled = strip.settledOrigin(proposed: 173, selectedRow: 11)
        #expect(settled == 180)
        #expect(settled + 430 < strip.top(ofRow: 11) + 60)
    }

    @Test("A highlight that stays whole through the snap does not divert it")
    func settlingSnapsNormallyWhenTheHighlightSurvives() {
        let strip = geometry(rows: 12, viewport: 469)
        #expect(strip.settledOrigin(proposed: 89, selectedRow: 1) == 60)
        #expect(strip.settledOrigin(proposed: 89, selectedRow: nil) == 60)
    }

    @Test("A viewport with no height yet asks for no reveal")
    func zeroHeightViewportRevealsNothing() {
        #expect(geometry(rows: 20, viewport: 0).revealOrigin(row: 15, currentOrigin: 0) == nil)
        #expect(geometry(rows: 20, viewport: 448).revealOrigin(row: 15, currentOrigin: 0) != nil)
    }

    @Test("Degenerate geometry asks for nothing")
    func degenerateGeometryIsInert() {
        #expect(geometry(rows: 0, top: Self.sourceListTop, viewport: 448).maximumRestingOrigin == 0)
        #expect(geometry(rows: 12, height: 0, viewport: 448).maximumRestingOrigin == 0)
        #expect(geometry(rows: 12, viewport: 0).bottomInset(documentHeight: 732) == 0)
        #expect(geometry(rows: 0, viewport: 448).revealOrigin(row: 0, currentOrigin: 0) == nil)
        #expect(geometry(rows: 12, viewport: 448).revealOrigin(row: 30, currentOrigin: 0) == nil)
        #expect(geometry(rows: 0, top: Self.sourceListTop, viewport: 448)
            .settledOrigin(proposed: 50, selectedRow: 0) == 0)
    }
}
