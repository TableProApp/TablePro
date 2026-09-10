//
//  CellEditorArrowExitTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// Up and Down carry the inline editor to the adjacent row, so a value that holds line breaks has
/// to keep them for its own lines and give them up only at the line at that end (#2569).
@Suite("Cell editor arrow exit")
struct CellEditorArrowExitTests {
    private func exit(_ value: String, selection: NSRange) -> CellEditorArrowExit {
        CellEditorArrowExit(text: value as NSString, selection: selection)
    }

    @Test("A single line leaves the cell in both directions")
    func singleLineLeavesInBothDirections() {
        let placement = exit("alpha", selection: NSRange(location: 2, length: 0))

        #expect(placement.canExitUp)
        #expect(placement.canExitDown)
    }

    /// The editor opens with the whole value selected, which is where the first arrow press lands.
    @Test("A fully selected single line still leaves the cell")
    func fullySelectedSingleLineStillLeaves() {
        let placement = exit("alpha", selection: NSRange(location: 0, length: 5))

        #expect(placement.canExitUp)
        #expect(placement.canExitDown)
    }

    @Test("An empty value leaves the cell in both directions")
    func emptyValueLeaves() {
        let placement = exit("", selection: NSRange(location: 0, length: 0))

        #expect(placement.canExitUp)
        #expect(placement.canExitDown)
    }

    @Test("The middle line of a multi-line value keeps both arrows")
    func middleLineKeepsBothArrows() {
        let placement = exit("a\nb\nc", selection: NSRange(location: 2, length: 0))

        #expect(!placement.canExitUp)
        #expect(!placement.canExitDown)
    }

    @Test("The first line of a multi-line value leaves upwards only")
    func firstLineLeavesUpwardsOnly() {
        let placement = exit("a\nb\nc", selection: NSRange(location: 0, length: 0))

        #expect(placement.canExitUp)
        #expect(!placement.canExitDown)
    }

    @Test("The last line of a multi-line value leaves downwards only")
    func lastLineLeavesDownwardsOnly() {
        let placement = exit("a\nb\nc", selection: NSRange(location: 5, length: 0))

        #expect(!placement.canExitUp)
        #expect(placement.canExitDown)
    }

    /// A caret sitting just before the closing break is still on the line above the empty one.
    @Test("A trailing break still counts as a line below")
    func trailingBreakCountsAsLineBelow() {
        let placement = exit("a\n", selection: NSRange(location: 1, length: 0))

        #expect(placement.canExitUp)
        #expect(!placement.canExitDown)
    }

    /// A selection is a text-editing gesture in its own right, so the arrow collapses it first and
    /// the press after that is the one that leaves.
    @Test("A selection inside a multi-line value keeps both arrows")
    func selectionInsideMultiLineKeepsBothArrows() {
        let placement = exit("a\nb\nc", selection: NSRange(location: 0, length: 5))

        #expect(!placement.canExitUp)
        #expect(!placement.canExitDown)
    }

    @Test("A carriage return starts a line the same way a newline does")
    func carriageReturnStartsALine() {
        let placement = exit("a\r\nb", selection: NSRange(location: 4, length: 0))

        #expect(!placement.canExitUp)
        #expect(placement.canExitDown)
    }

    /// The selection comes from the text view, so it is already inside the value, but a stale one
    /// must not read past the end.
    @Test("A selection past the end of the value is clamped")
    func selectionPastTheEndIsClamped() {
        let placement = exit("alpha", selection: NSRange(location: 40, length: 10))

        #expect(placement.canExitUp)
        #expect(placement.canExitDown)
    }
}
