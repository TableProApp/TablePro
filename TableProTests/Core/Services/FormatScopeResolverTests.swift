//
//  FormatScopeResolverTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct FormatScopeResolverTests {
    private let text = "SELECT * FROM users;\nSELECT * FROM orders;"

    @Test("No selection resolves to the full document")
    func noSelectionReturnsFullRange() {
        let scope = FormatScopeResolver.resolve(fullText: text, selectedRange: NSRange(location: 0, length: 0))
        #expect(scope.range == NSRange(location: 0, length: (text as NSString).length))
        #expect(scope.sql == text)
        #expect(scope.cursorOffset == 0)
    }

    @Test("No selection keeps the cursor offset for caret mapping")
    func noSelectionCursorMidDocument() {
        let scope = FormatScopeResolver.resolve(fullText: text, selectedRange: NSRange(location: 10, length: 0))
        #expect(scope.range == NSRange(location: 0, length: (text as NSString).length))
        #expect(scope.cursorOffset == 10)
    }

    @Test("A selection resolves to exactly the selected subrange")
    func selectionReturnsSubrange() {
        let selection = NSRange(location: 21, length: 21)
        let scope = FormatScopeResolver.resolve(fullText: text, selectedRange: selection)
        #expect(scope.range == selection)
        #expect(scope.sql == "SELECT * FROM orders;")
        #expect(scope.cursorOffset == nil)
    }

    @Test("A selection covering the whole document behaves like a selection")
    func selectionCoversWholeDocument() {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let scope = FormatScopeResolver.resolve(fullText: text, selectedRange: fullRange)
        #expect(scope.range == fullRange)
        #expect(scope.sql == text)
        #expect(scope.cursorOffset == nil)
    }

    @Test("NSNotFound selection is treated as no selection")
    func notFoundLocationTreatedAsNoSelection() {
        let scope = FormatScopeResolver.resolve(
            fullText: text,
            selectedRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(scope.range == NSRange(location: 0, length: (text as NSString).length))
        #expect(scope.cursorOffset == 0)
    }

    @Test("A selection extending past the document falls back to the full document")
    func outOfBoundsSelectionFallsBack() {
        let scope = FormatScopeResolver.resolve(
            fullText: text,
            selectedRange: NSRange(location: 30, length: 500)
        )
        #expect(scope.range == NSRange(location: 0, length: (text as NSString).length))
        #expect(scope.cursorOffset == 30)
    }

    @Test("Scope reports whether it came from a selection")
    func scopeReportsSelectionOrigin() {
        let noSelection = FormatScopeResolver.resolve(fullText: text, selectedRange: NSRange(location: 0, length: 0))
        #expect(noSelection.isSelection == false)
        let selection = FormatScopeResolver.resolve(fullText: text, selectedRange: NSRange(location: 0, length: 6))
        #expect(selection.isSelection)
    }

    @Test("A selection ending in a newline keeps the newline after formatting")
    func trailingNewlinePreserved() {
        let spliced = FormatScopeResolver.reapplyBoundaryWhitespace(
            from: "select * from users;\n",
            to: "SELECT *\nFROM users;"
        )
        #expect(spliced == "SELECT *\nFROM users;\n")
    }

    @Test("Leading and trailing whitespace of the selection both survive formatting")
    func leadingAndTrailingWhitespacePreserved() {
        let spliced = FormatScopeResolver.reapplyBoundaryWhitespace(
            from: "\n  select 1; \n\n",
            to: "SELECT 1;"
        )
        #expect(spliced == "\n  SELECT 1; \n\n")
    }

    @Test("Whitespace-only original returns the formatted text unchanged")
    func whitespaceOnlyOriginalReturnsFormatted() {
        let spliced = FormatScopeResolver.reapplyBoundaryWhitespace(from: "  \n ", to: "SELECT 1;")
        #expect(spliced == "SELECT 1;")
    }

    @Test("Original without boundary whitespace returns the formatted text unchanged")
    func noBoundaryWhitespaceReturnsFormatted() {
        let spliced = FormatScopeResolver.reapplyBoundaryWhitespace(from: "select 1;", to: "SELECT 1;")
        #expect(spliced == "SELECT 1;")
    }

    @Test("Unicode text resolves ranges in UTF-16 units")
    func unicodeRangesUseUTF16() {
        let unicodeText = "SELECT '😀' AS emoji;\nSELECT 1;"
        let nsText = unicodeText as NSString
        let secondStatement = NSRange(location: nsText.length - 9, length: 9)
        let scope = FormatScopeResolver.resolve(fullText: unicodeText, selectedRange: secondStatement)
        #expect(scope.sql == "SELECT 1;")
        #expect(scope.range == secondStatement)
    }
}
