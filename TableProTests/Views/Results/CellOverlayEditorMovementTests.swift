//
//  CellOverlayEditorMovementTests.swift
//  TableProTests
//

import AppKit
import Foundation
import Testing

@testable import TablePro

/// The overlay is a text view rather than a field editor, so the four selectors AppKit would have
/// turned into an `NSTextMovement` are read here instead (#2569).
@Suite("Cell overlay editor movement")
@MainActor
struct CellOverlayEditorMovementTests {
    private struct Editing {
        let editor: CellOverlayEditor
        let textView: NSTextView
        let tableView: KeyHandlingTableView
    }

    private func makeEditing(value: String, selection: NSRange) -> Editing {
        let tableView = KeyHandlingTableView()
        let editor = CellOverlayEditor()
        editor.install(
            in: tableView,
            row: 4,
            column: 2,
            columnIndex: 1,
            container: CellOverlayContainerView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        CellOverlayBase.applyCellTextLayout(to: textView)
        textView.string = value
        textView.setSelectedRange(selection)
        return Editing(editor: editor, textView: textView, tableView: tableView)
    }

    private struct Outcome {
        let handled: Bool
        let movement: CellEditorMovement?
        let cell: (row: Int, column: Int)?
    }

    private func send(_ selector: Selector, to editing: Editing) -> Outcome {
        var movement: CellEditorMovement?
        var cell: (row: Int, column: Int)?
        editing.editor.onMovement = { row, column, reported in
            movement = reported
            cell = (row, column)
        }
        let handled = editing.editor.textView(editing.textView, doCommandBy: selector)
        editing.editor.removeOverlay()
        return Outcome(handled: handled, movement: movement, cell: cell)
    }

    @Test("Down leaves a single-line value for the row below")
    func downLeavesSingleLineValue() throws {
        let editing = makeEditing(value: "alpha", selection: NSRange(location: 0, length: 5))

        let result = send(#selector(NSResponder.moveDown(_:)), to: editing)

        #expect(result.handled)
        #expect(result.movement == .down)
        let cell = try #require(result.cell)
        #expect(cell.row == 4)
        #expect(cell.column == 2)
    }

    @Test("Up leaves a single-line value for the row above")
    func upLeavesSingleLineValue() {
        let editing = makeEditing(value: "alpha", selection: NSRange(location: 2, length: 0))

        let result = send(#selector(NSResponder.moveUp(_:)), to: editing)

        #expect(result.handled)
        #expect(result.movement == .up)
    }

    @Test("Down inside a multi-line value stays in the text view")
    func downInsideMultiLineValueStays() {
        let editing = makeEditing(value: "a\nb\nc", selection: NSRange(location: 0, length: 0))

        let result = send(#selector(NSResponder.moveDown(_:)), to: editing)

        #expect(!result.handled)
        #expect(result.movement == nil)
    }

    @Test("Down from the last line of a multi-line value leaves the cell")
    func downFromLastLineLeaves() {
        let editing = makeEditing(value: "a\nb\nc", selection: NSRange(location: 5, length: 0))

        let result = send(#selector(NSResponder.moveDown(_:)), to: editing)

        #expect(result.handled)
        #expect(result.movement == .down)
    }

    /// Shift+Down is `moveDownAndModifySelection:`, so extending a selection keeps its own meaning.
    @Test("A selection-extending arrow is left to the text view")
    func selectionExtendingArrowIsLeftAlone() {
        let editing = makeEditing(value: "alpha", selection: NSRange(location: 0, length: 0))

        let result = send(#selector(NSResponder.moveDownAndModifySelection(_:)), to: editing)

        #expect(!result.handled)
        #expect(result.movement == nil)
    }

    /// The text view holds provisional text until the input method commits it, so a movement here
    /// would save a half-composed value. The arrow goes back to the composition, which is what
    /// moves the caret through it; Tab is swallowed rather than turned into a literal tab.
    @Test("An arrow during an IME composition stays with the composition")
    func arrowDuringCompositionStaysWithTheComposition() {
        let editing = makeEditing(value: "", selection: NSRange(location: 0, length: 0))
        editing.textView.setMarkedText(
            "\u{304B}",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 0, length: 0)
        )

        let result = send(#selector(NSResponder.moveDown(_:)), to: editing)

        #expect(editing.textView.hasMarkedText())
        #expect(!result.handled)
        #expect(result.movement == nil)
    }

    @Test("Tab during an IME composition is swallowed rather than leaving the cell")
    func tabDuringCompositionIsSwallowed() {
        let editing = makeEditing(value: "", selection: NSRange(location: 0, length: 0))
        editing.textView.setMarkedText(
            "\u{304B}",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 0, length: 0)
        )

        let result = send(#selector(NSResponder.insertTab(_:)), to: editing)

        #expect(result.handled)
        #expect(result.movement == nil)
    }

    @Test("Tab and Shift+Tab report their own movements")
    func tabAndBacktabReportTheirMovements() {
        let caret = NSRange(location: 0, length: 0)
        let forward = send(#selector(NSResponder.insertTab(_:)), to: makeEditing(value: "alpha", selection: caret))
        let backward = send(#selector(NSResponder.insertBacktab(_:)), to: makeEditing(value: "alpha", selection: caret))

        #expect(forward.handled)
        #expect(forward.movement == .tab)
        #expect(backward.handled)
        #expect(backward.movement == .backtab)
    }
}
