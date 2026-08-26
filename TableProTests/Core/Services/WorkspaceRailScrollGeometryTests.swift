//
//  WorkspaceRailScrollGeometryTests.swift
//  TableProTests
//
//  The strip used to come to rest wherever a scroll left it, which cut the glyph off the entry at
//  the top of the viewport and was reported as a drawing bug (#2452). These pin the offsets it is
//  allowed to rest on.
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("Workspace rail scroll geometry")
struct WorkspaceRailScrollGeometryTests {
    private static let layouts = [
        WorkspaceRailMetrics.small,
        WorkspaceRailMetrics.medium,
        WorkspaceRailMetrics.large,
    ]

    @Test("Row pitch is the row plus the spacing between rows")
    func rowPitchCombinesHeightAndSpacing() {
        for layout in Self.layouts {
            #expect(layout.rowPitch == layout.rowHeight + layout.rowSpacing)
            #expect(layout.rowPitch > layout.rowHeight)
        }
    }

    @Test("A strip whose entries fit cannot rest anywhere but the top")
    func fittingStripRestsAtTheTop() {
        let maximum = WorkspaceRailScrollGeometry.maximumRestingOrigin(
            rowCount: 6, rowPitch: 60, rowHeight: 58, viewportHeight: 448
        )
        #expect(maximum == 0)
        #expect(WorkspaceRailScrollGeometry.settledOrigin(
            proposed: 137, rowPitch: 60, maximumOrigin: maximum
        ) == 0)
    }

    @Test("The furthest resting offset keeps the last entry whole")
    func maximumRestingOriginKeepsTheLastEntryWhole() {
        let maximum = WorkspaceRailScrollGeometry.maximumRestingOrigin(
            rowCount: 12, rowPitch: 60, rowHeight: 58, viewportHeight: 448
        )
        #expect(maximum == 300)
        let lastEntryBottom = 11 * CGFloat(60) + 58
        #expect(maximum + 448 >= lastEntryBottom)
        #expect(maximum.truncatingRemainder(dividingBy: 60) == 0)
    }

    @Test("The bottom inset is what brings the furthest offset within reach")
    func bottomInsetMakesTheLastOffsetReachable() {
        let documentHeight: CGFloat = 732
        let viewportHeight: CGFloat = 448
        let inset = WorkspaceRailScrollGeometry.bottomInset(
            rowCount: 12, rowPitch: 60, rowHeight: 58,
            documentHeight: documentHeight, viewportHeight: viewportHeight
        )
        let maximum = WorkspaceRailScrollGeometry.maximumRestingOrigin(
            rowCount: 12, rowPitch: 60, rowHeight: 58, viewportHeight: viewportHeight
        )
        #expect(documentHeight - viewportHeight < maximum)
        #expect(documentHeight - viewportHeight + inset == maximum)
    }

    @Test("A strip that needs no scrolling asks for no inset")
    func fittingStripNeedsNoInset() {
        #expect(WorkspaceRailScrollGeometry.bottomInset(
            rowCount: 4, rowPitch: 60, rowHeight: 58, documentHeight: 448, viewportHeight: 448
        ) == 0)
    }

    @Test("Every settled offset lands on an entry boundary, at every layout")
    func everySettledOffsetLandsOnABoundary() {
        for layout in Self.layouts {
            let pitch = layout.rowPitch
            for viewportHeight in stride(from: CGFloat(200), through: 900, by: 37) {
                let maximum = WorkspaceRailScrollGeometry.maximumRestingOrigin(
                    rowCount: 20, rowPitch: pitch, rowHeight: layout.rowHeight,
                    viewportHeight: viewportHeight
                )
                for proposed in stride(from: CGFloat(-40), through: maximum + 200, by: 11) {
                    let settled = WorkspaceRailScrollGeometry.settledOrigin(
                        proposed: proposed, rowPitch: pitch, maximumOrigin: maximum
                    )
                    #expect(settled >= 0)
                    #expect(settled <= maximum)
                    #expect(abs(settled.truncatingRemainder(dividingBy: pitch)) < 0.001)
                }
            }
        }
    }

    @Test("Settling never rounds up past the furthest offset")
    func settlingNeverOvershootsTheMaximum() {
        let maximum = WorkspaceRailScrollGeometry.maximumRestingOrigin(
            rowCount: 12, rowPitch: 60, rowHeight: 58, viewportHeight: 448
        )
        #expect(WorkspaceRailScrollGeometry.settledOrigin(
            proposed: maximum + 500, rowPitch: 60, maximumOrigin: maximum
        ) == maximum)
        #expect(WorkspaceRailScrollGeometry.settledOrigin(
            proposed: 289, rowPitch: 60, maximumOrigin: maximum
        ) == maximum)
    }

    @Test("An entry already whole and on screen is left alone")
    func visibleEntryIsNotRevealed() {
        #expect(WorkspaceRailScrollGeometry.revealOrigin(
            row: 2, rowCount: 12, rowPitch: 60, rowHeight: 58,
            viewportHeight: 448, currentOrigin: 0
        ) == nil)
    }

    @Test("An entry above the viewport is revealed at its own top edge")
    func entryAboveIsRevealedAtItsTop() {
        let origin = WorkspaceRailScrollGeometry.revealOrigin(
            row: 1, rowCount: 12, rowPitch: 60, rowHeight: 58,
            viewportHeight: 448, currentOrigin: 300
        )
        #expect(origin == 60)
    }

    @Test("An entry below the viewport is revealed whole, on a boundary")
    func entryBelowIsRevealedWholeOnABoundary() {
        let viewportHeight: CGFloat = 448
        let origin = WorkspaceRailScrollGeometry.revealOrigin(
            row: 9, rowCount: 12, rowPitch: 60, rowHeight: 58,
            viewportHeight: viewportHeight, currentOrigin: 0
        ) ?? -1
        #expect(origin >= 0)
        #expect(origin.truncatingRemainder(dividingBy: 60) == 0)
        #expect(origin <= 9 * CGFloat(60))
        #expect(origin + viewportHeight >= 9 * CGFloat(60) + 58)
    }

    @Test("Revealing the last entry lands exactly on the furthest resting offset")
    func lastEntryIsReachableWhole() {
        for layout in Self.layouts {
            let pitch = layout.rowPitch
            let viewportHeight: CGFloat = 448
            let rowCount = 20
            let maximum = WorkspaceRailScrollGeometry.maximumRestingOrigin(
                rowCount: rowCount, rowPitch: pitch, rowHeight: layout.rowHeight,
                viewportHeight: viewportHeight
            )
            let origin = WorkspaceRailScrollGeometry.revealOrigin(
                row: rowCount - 1, rowCount: rowCount, rowPitch: pitch, rowHeight: layout.rowHeight,
                viewportHeight: viewportHeight, currentOrigin: 0
            )
            #expect(origin == maximum)
            let lastEntryBottom = CGFloat(rowCount - 1) * pitch + layout.rowHeight
            #expect(maximum + viewportHeight >= lastEntryBottom)
        }
    }

    @Test("A viewport that ends inside the spacing under the last entry still holds them all")
    func viewportEndingInTrailingSpacingCountsAsFitting() {
        let viewportHeight = 7 * CGFloat(60) + 58
        #expect(WorkspaceRailScrollGeometry.maximumRestingOrigin(
            rowCount: 8, rowPitch: 60, rowHeight: 58, viewportHeight: viewportHeight
        ) == 0)
        #expect(WorkspaceRailScrollGeometry.bottomInset(
            rowCount: 8, rowPitch: 60, rowHeight: 58,
            documentHeight: viewportHeight, viewportHeight: viewportHeight
        ) == 0)
    }

    @Test("Settling does not cut an entry the highlight was showing whole")
    func settlingKeepsAWholeHighlightWhole() {
        let viewportHeight: CGFloat = 469
        let settled = WorkspaceRailScrollGeometry.settledOrigin(
            proposed: 89, selectedRow: 8, rowCount: 12,
            rowPitch: 60, rowHeight: 58, viewportHeight: viewportHeight
        )
        #expect(settled.truncatingRemainder(dividingBy: 60) == 0)
        let entryTop = 8 * CGFloat(60)
        #expect(settled <= entryTop)
        #expect(settled + viewportHeight >= entryTop + 58)
    }

    @Test("Scrolling away from the highlighted entry settles where the scroll ended")
    func settlingDoesNotTetherToAnOffScreenHighlight() {
        let viewportHeight: CGFloat = 430
        let settled = WorkspaceRailScrollGeometry.settledOrigin(
            proposed: 173, selectedRow: 11, rowCount: 12,
            rowPitch: 60, rowHeight: 58, viewportHeight: viewportHeight
        )
        #expect(settled == 180)
        let entryTop = 11 * CGFloat(60)
        #expect(settled + viewportHeight < entryTop + 58)
    }

    @Test("A highlight that stays whole through the snap does not divert it")
    func settlingSnapsNormallyWhenTheHighlightSurvives() {
        #expect(WorkspaceRailScrollGeometry.settledOrigin(
            proposed: 89, selectedRow: 1, rowCount: 12,
            rowPitch: 60, rowHeight: 58, viewportHeight: 469
        ) == 60)
        #expect(WorkspaceRailScrollGeometry.settledOrigin(
            proposed: 89, selectedRow: nil, rowCount: 12,
            rowPitch: 60, rowHeight: 58, viewportHeight: 469
        ) == 60)
    }

    @Test("A viewport with no height yet asks for no reveal")
    func zeroHeightViewportRevealsNothing() {
        #expect(WorkspaceRailScrollGeometry.revealOrigin(
            row: 15, rowCount: 20, rowPitch: 60, rowHeight: 58,
            viewportHeight: 0, currentOrigin: 0
        ) == nil)
        #expect(WorkspaceRailScrollGeometry.revealOrigin(
            row: 15, rowCount: 20, rowPitch: 60, rowHeight: 58,
            viewportHeight: 448, currentOrigin: 0
        ) != nil)
    }

    @Test("Degenerate geometry asks for nothing")
    func degenerateGeometryIsInert() {
        #expect(WorkspaceRailScrollGeometry.maximumRestingOrigin(
            rowCount: 0, rowPitch: 60, rowHeight: 58, viewportHeight: 448
        ) == 0)
        #expect(WorkspaceRailScrollGeometry.maximumRestingOrigin(
            rowCount: 12, rowPitch: 0, rowHeight: 58, viewportHeight: 448
        ) == 0)
        #expect(WorkspaceRailScrollGeometry.bottomInset(
            rowCount: 12, rowPitch: 60, rowHeight: 58, documentHeight: 732, viewportHeight: 0
        ) == 0)
        #expect(WorkspaceRailScrollGeometry.revealOrigin(
            row: 0, rowCount: 0, rowPitch: 60, rowHeight: 58,
            viewportHeight: 448, currentOrigin: 0
        ) == nil)
        #expect(WorkspaceRailScrollGeometry.revealOrigin(
            row: 30, rowCount: 12, rowPitch: 60, rowHeight: 58,
            viewportHeight: 448, currentOrigin: 0
        ) == nil)
    }
}
