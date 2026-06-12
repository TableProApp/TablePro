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
