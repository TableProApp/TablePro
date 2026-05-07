//
//  LineCutCalculatorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Line Cut Calculator")
struct LineCutCalculatorTests {
    // MARK: - With Selection (existing Cmd+X behavior must not regress)

    @Test("Selection cuts only the selected text")
    func selectionCutsSelectedText() {
        let result = LineCutCalculator.calculate(
            text: "hello world",
            selection: NSRange(location: 6, length: 5)
        )
        #expect(result == LineCutCalculator.Result(
            rangeToDelete: NSRange(location: 6, length: 5),
            clipboardText: "world"
        ))
    }

    @Test("Multi-line selection cuts only the selected substring")
    func multiLineSelectionCutsSubstring() {
        let result = LineCutCalculator.calculate(
            text: "line1\nline2\nline3",
            selection: NSRange(location: 3, length: 6)
        )
        #expect(result == LineCutCalculator.Result(
            rangeToDelete: NSRange(location: 3, length: 6),
            clipboardText: "e1\nlin"
        ))
    }

    // MARK: - No Selection: cut current line (issue #1075)

    @Test("Single line without terminator cuts the entire content")
    func singleLineNoTerminatorCutsAll() {
        let result = LineCutCalculator.calculate(
            text: "select * from users",
            selection: NSRange(location: 5, length: 0)
        )
        #expect(result == LineCutCalculator.Result(
            rangeToDelete: NSRange(location: 0, length: 19),
            clipboardText: "select * from users"
        ))
    }

    @Test("First line of multi-line cuts line plus trailing newline")
    func firstLineCutsWithNewline() {
        let result = LineCutCalculator.calculate(
            text: "line1\nline2\nline3",
            selection: NSRange(location: 2, length: 0)
        )
        #expect(result == LineCutCalculator.Result(
            rangeToDelete: NSRange(location: 0, length: 6),
            clipboardText: "line1\n"
        ))
    }

    @Test("Middle line cuts line plus trailing newline")
    func middleLineCutsWithNewline() {
        let result = LineCutCalculator.calculate(
            text: "line1\nline2\nline3",
            selection: NSRange(location: 8, length: 0)
        )
        #expect(result == LineCutCalculator.Result(
            rangeToDelete: NSRange(location: 6, length: 6),
            clipboardText: "line2\n"
        ))
    }

    @Test("Last line without trailing newline cuts the line text only")
    func lastLineNoTerminatorCutsLineOnly() {
        let result = LineCutCalculator.calculate(
            text: "line1\nline2\nline3",
            selection: NSRange(location: 14, length: 0)
        )
        #expect(result == LineCutCalculator.Result(
            rangeToDelete: NSRange(location: 12, length: 5),
            clipboardText: "line3"
        ))
    }

    @Test("Last line with trailing newline cuts line plus newline")
    func lastLineWithTerminatorCutsWithNewline() {
        let result = LineCutCalculator.calculate(
            text: "line1\nline2\n",
            selection: NSRange(location: 8, length: 0)
        )
        #expect(result == LineCutCalculator.Result(
            rangeToDelete: NSRange(location: 6, length: 6),
            clipboardText: "line2\n"
        ))
    }

    @Test("Cursor at start of line cuts that line")
    func cursorAtStartOfLineCutsLine() {
        let result = LineCutCalculator.calculate(
            text: "line1\nline2\nline3",
            selection: NSRange(location: 6, length: 0)
        )
        #expect(result == LineCutCalculator.Result(
            rangeToDelete: NSRange(location: 6, length: 6),
            clipboardText: "line2\n"
        ))
    }

    @Test("Cursor between line text and trailing newline cuts that line")
    func cursorBeforeNewlineCutsLine() {
        let result = LineCutCalculator.calculate(
            text: "line1\nline2\nline3",
            selection: NSRange(location: 5, length: 0)
        )
        #expect(result == LineCutCalculator.Result(
            rangeToDelete: NSRange(location: 0, length: 6),
            clipboardText: "line1\n"
        ))
    }

    @Test("Cursor on empty line cuts just the newline")
    func cursorOnEmptyLineCutsNewline() {
        let result = LineCutCalculator.calculate(
            text: "line1\n\nline3",
            selection: NSRange(location: 6, length: 0)
        )
        #expect(result == LineCutCalculator.Result(
            rangeToDelete: NSRange(location: 6, length: 1),
            clipboardText: "\n"
        ))
    }

    // MARK: - No-op cases

    @Test("Empty text returns nil")
    func emptyTextReturnsNil() {
        let result = LineCutCalculator.calculate(
            text: "",
            selection: NSRange(location: 0, length: 0)
        )
        #expect(result == nil)
    }

    @Test("Cursor past end of text returns nil")
    func cursorOutOfBoundsReturnsNil() {
        let result = LineCutCalculator.calculate(
            text: "abc",
            selection: NSRange(location: 100, length: 0)
        )
        #expect(result == nil)
    }

    @Test("Cursor at end of buffer with trailing newline returns nil (no line below)")
    func cursorAtTrailingEmptyLineReturnsNil() {
        let result = LineCutCalculator.calculate(
            text: "line1\n",
            selection: NSRange(location: 6, length: 0)
        )
        #expect(result == nil)
    }
}
