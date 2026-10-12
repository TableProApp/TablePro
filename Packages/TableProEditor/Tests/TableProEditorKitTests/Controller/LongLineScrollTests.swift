//
//  SQLEditorLongLineScrollTests.swift
//  TableProEditorKitTests
//

import AppKit
@testable import TableProEditorKit
import TableProTextEngine
import Testing

/// Pasting a long line into the query editor and taking it back out leaves the start of every line in view (#2709).
@Suite("Long line scroll")
@MainActor
struct SQLEditorLongLineScrollTests {
    private let query = "SELECT * FROM pay_order\nORDER BY orderId desc\n"
    private let pastedRow = String(repeating: "2056705 20260908142922 0.01 2026-09-15 14:29:40 ", count: 20)

    @Test("Undoing a long paste narrows the editor and brings back the start of every line")
    func undoingALongPasteReturnsToTheLineStarts() throws {
        let controller = Mock.loadedTextViewController(string: query)
        let end = (query as NSString).length
        let narrowWidth = controller.textView.frame.width

        controller.textView.selectionManager.setSelectedRange(NSRange(location: end, length: 0))
        controller.textView.replaceCharacters(in: NSRange(location: end, length: 0), with: pastedRow)
        controller.textView.layoutManager.layoutLines()
        try #require(controller.scrollPosition.x > 0, "Pasting follows the caret out to the end of the long line")

        controller.textView.undoManager?.undo()
        controller.textView.layoutManager.layoutLines()

        #expect(controller.textView.string == query)
        #expect(controller.textView.frame.width == narrowWidth)
        #expect(abs(controller.scrollPosition.x) <= 0.5, "The start of each line is scrolled away by \(controller.scrollPosition.x)")
    }

    @Test("The start of a line is never left under the gutter")
    func lineStartClearsTheGutter() throws {
        let controller = Mock.loadedTextViewController(string: pastedRow + "\n" + query)
        controller.textView.scroll(NSPoint(x: 1_000_000, y: 0))

        let lineStart = (pastedRow as NSString).length + 1
        controller.textView.selectionManager.setSelectedRange(NSRange(location: lineStart, length: 0))
        controller.textView.scrollSelectionToVisible()

        let character = try #require(controller.textView.layoutManager.rectForOffset(lineStart))
        let gutter = try #require(controller.gutterView)
        let characterX = controller.textView.convert(character.origin, to: nil).x
        let gutterMaxX = gutter.convert(NSPoint(x: gutter.bounds.maxX, y: 0), to: nil).x
        #expect(characterX >= gutterMaxX - 0.5, "The line starts \(gutterMaxX - characterX)pt under the gutter")
    }

    @Test("A long line scrolled a few points in stays there when the editor is laid out again (#2841)")
    func positionNearTheLineStartSurvivesLayout() throws {
        let controller = Mock.loadedTextViewController(string: pastedRow + "\n" + query)
        controller.textView.layoutManager.layoutLines()
        controller.scrollPosition = CGPoint(x: 20, y: 0)
        try #require(abs(controller.scrollPosition.x - 20) <= 0.5, "Scrolled to \(controller.scrollPosition.x)")

        controller.scrollView.tile()
        controller.scrollView.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()

        #expect(abs(controller.scrollPosition.x - 20) <= 0.5, "Laying out moved the view to \(controller.scrollPosition.x)")
    }
}
