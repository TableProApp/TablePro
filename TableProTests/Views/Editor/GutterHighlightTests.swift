//
//  GutterHighlightTests.swift
//  TableProTests
//
//  Regression tests for gutter line-number highlighting at end of document.
//  Originally the gutter tested membership via `IndexSet.intersects(integersIn: lineRange)`,
//  but NSRange is half-open — so a caret at offset == document length never intersected
//  any line and the line number lost its highlight color even though the line background
//  stayed shaded.
//

import AppKit
@testable import CodeEditSourceEditor
import CodeEditTextView
import Testing

@MainActor
@Suite("GutterView highlight at end of document")
struct GutterHighlightTests {
    private func setText(_ text: String, on controller: TextViewController) {
        controller.textView.setText(text)
        controller.textView.layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1_000, height: 1_000))
    }

    @Test("Caret at end of single-line query highlights the only line")
    func caretAtEndOfSingleLineHighlightsLine() throws {
        let controller = EditorControllerFixture.make()
        setText("SELECT * FROM users", on: controller)
        let length = controller.textView.length
        controller.textView.selectionManager.setSelectedRange(NSRange(location: length, length: 0))

        let highlighted = controller.gutterView.highlightedLineIDs()
        let firstID = try #require(controller.textView.layoutManager.lineStorage.first?.data.id)
        #expect(highlighted.contains(firstID))
    }

    @Test("Caret at end of multi-line query highlights only the last line")
    func caretAtEndOfMultiLineHighlightsLastLine() throws {
        let controller = EditorControllerFixture.make()
        setText("abc\ndef", on: controller)
        let length = controller.textView.length
        controller.textView.selectionManager.setSelectedRange(NSRange(location: length, length: 0))

        let highlighted = controller.gutterView.highlightedLineIDs()
        let firstID = try #require(controller.textView.layoutManager.lineStorage.first?.data.id)
        let lastID = try #require(controller.textView.layoutManager.lineStorage.last?.data.id)
        #expect(highlighted.contains(lastID))
        #expect(!highlighted.contains(firstID))
    }

    @Test("Caret in middle of line highlights that line")
    func caretInMiddleOfLineHighlightsThatLine() throws {
        let controller = EditorControllerFixture.make()
        setText("abc\ndef", on: controller)
        controller.textView.selectionManager.setSelectedRange(NSRange(location: 1, length: 0))

        let highlighted = controller.gutterView.highlightedLineIDs()
        let firstID = try #require(controller.textView.layoutManager.lineStorage.first?.data.id)
        let lastID = try #require(controller.textView.layoutManager.lineStorage.last?.data.id)
        #expect(highlighted.contains(firstID))
        #expect(!highlighted.contains(lastID))
    }
}
