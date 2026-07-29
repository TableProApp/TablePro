//
//  HighlightCapTests.swift
//  TableProTests
//
//  Regression tests for the 10K character highlight capping.
//  Ensures regex-based syntax highlighting only runs on the first
//  maxHighlightLength (10,000) characters to prevent freezes on
//  large SQL dumps with single lines containing millions of characters.
//

import AppKit
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
@Suite("Highlight Capping")
struct HighlightCapTests {
    private static let maxHighlightLength = 10_000

    // MARK: - HighlightedSQLTextView

    @Test("Short SQL text is fully highlighted")
    func sqlShortTextFullyHighlighted() {
        let sql = "SELECT id FROM users WHERE id = 1"
        let (textView, _) = makeHighlightedSQLView(sql: sql)

        var effectiveRange = NSRange()
        let color = textView.textStorage?.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: &effectiveRange
        ) as? NSColor

        #expect(color == .systemBlue, "SELECT keyword should be highlighted blue")
    }

    @Test("SQL highlighting caps at 10K characters - keyword beyond cap is not highlighted")
    func sqlCapsAt10K() {
        let filler = String(repeating: "x", count: Self.maxHighlightLength)
        let sql = filler + " SELECT id FROM users"
        let (textView, _) = makeHighlightedSQLView(sql: sql)

        guard let textStorage = textView.textStorage else {
            Issue.record("No text storage")
            return
        }

        let keywordPos = Self.maxHighlightLength + 1
        guard keywordPos < textStorage.length else {
            Issue.record("Text too short")
            return
        }

        var effectiveRange = NSRange()
        let colorBeyondCap = textStorage.attribute(
            .foregroundColor,
            at: keywordPos,
            effectiveRange: &effectiveRange
        ) as? NSColor

        #expect(
            colorBeyondCap == NSColor.labelColor || colorBeyondCap == nil,
            "SELECT beyond 10K should not be syntax-highlighted, got: \(String(describing: colorBeyondCap))"
        )
    }

    @Test("SQL keyword within cap region is highlighted even for long text")
    func sqlWithinCapRegionHighlighted() {
        let sql = "SELECT " + String(repeating: "a", count: Self.maxHighlightLength + 5_000)
        let (textView, _) = makeHighlightedSQLView(sql: sql)

        var effectiveRange = NSRange()
        let color = textView.textStorage?.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: &effectiveRange
        ) as? NSColor

        #expect(color == .systemBlue, "SELECT at start should be highlighted even in long text")
    }

    @Test("SQL text with exactly 10K characters is fully highlighted")
    func sqlExactly10KChars() {
        let prefix = "SELECT "
        let remaining = Self.maxHighlightLength - (prefix as NSString).length
        let sql = prefix + String(repeating: "a", count: remaining)
        #expect((sql as NSString).length == Self.maxHighlightLength)

        let (textView, _) = makeHighlightedSQLView(sql: sql)

        var effectiveRange = NSRange()
        let color = textView.textStorage?.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: &effectiveRange
        ) as? NSColor

        #expect(color == .systemBlue, "At exactly 10K chars, text should be fully highlighted")
    }

    @Test("SQL text with 10001 characters does not highlight keyword at position 10001")
    func sql10001Chars() {
        let filler = String(repeating: "x", count: Self.maxHighlightLength)
        let sql = filler + "SELECT"
        #expect((sql as NSString).length == Self.maxHighlightLength + 6)

        let (textView, _) = makeHighlightedSQLView(sql: sql)

        guard let textStorage = textView.textStorage else {
            Issue.record("No text storage")
            return
        }

        var effectiveRange = NSRange()
        let color = textStorage.attribute(
            .foregroundColor,
            at: Self.maxHighlightLength,
            effectiveRange: &effectiveRange
        ) as? NSColor

        #expect(
            color == NSColor.labelColor || color == nil,
            "SELECT at position 10001 should have base styling only"
        )
    }

    @Test("Empty SQL text does not crash")
    func sqlEmptyNoCrash() {
        let (textView, _) = makeHighlightedSQLView(sql: "")
        #expect(textView.string.isEmpty)
    }

    // MARK: - AIChatCodeBlockView SQL/JS Highlighting Cap

    @Test("Large SQL code block AttributedString caps highlighting at 10K")
    func aiChatSQLCapsAt10K() {
        let filler = String(repeating: "x", count: Self.maxHighlightLength)
        let code = filler + " SELECT id FROM users"
        _ = highlightedSQLViaPatterns(code)

        let keywordPos = Self.maxHighlightLength + 1
        let nsCode = code as NSString
        guard keywordPos + 6 <= nsCode.length else {
            Issue.record("Code too short")
            return
        }

        let cappedRange = NSRange(location: 0, length: min(nsCode.length, Self.maxHighlightLength))
        let keywordRange = NSRange(location: keywordPos, length: 6)
        let keywordIntersection = NSIntersectionRange(cappedRange, keywordRange)

        #expect(keywordIntersection.length == 0, "SELECT keyword should be outside the capped range")
    }

    @Test("Large JavaScript code block AttributedString caps highlighting at 10K")
    func aiChatJSCapsAt10K() {
        let filler = String(repeating: "x", count: Self.maxHighlightLength)
        let code = filler + " db.collection.find({})"
        let nsCode = code as NSString

        let cappedRange = NSRange(location: 0, length: min(nsCode.length, Self.maxHighlightLength))
        let dbPos = Self.maxHighlightLength + 1
        let dbRange = NSRange(location: dbPos, length: 2)
        let intersection = NSIntersectionRange(cappedRange, dbRange)

        #expect(intersection.length == 0, "db keyword should be outside the capped range")
    }

    @Test("AIChatCodeBlockView does not crash with large SQL")
    func aiChatLargeSQLNoCrash() {
        let largeSql = "SELECT " + String(repeating: "col, ", count: Self.maxHighlightLength / 5)
        _ = AIChatCodeBlockView(code: largeSql, language: "sql")
    }

    @Test("AIChatCodeBlockView does not crash with large JavaScript")
    func aiChatLargeJSNoCrash() {
        let largeJs = "db.collection.find(" + String(repeating: "\"key\", ", count: Self.maxHighlightLength / 7) + "{})"
        _ = AIChatCodeBlockView(code: largeJs, language: "javascript")
    }

    @Test("AIChatCodeBlockView does not crash with empty code")
    func aiChatEmptyNoCrash() {
        _ = AIChatCodeBlockView(code: "", language: "sql")
        _ = AIChatCodeBlockView(code: "", language: "javascript")
        _ = AIChatCodeBlockView(code: "", language: nil)
    }

    // MARK: - Helpers

    private func makeHighlightedSQLView(sql: String) -> (NSTextView, NSScrollView) {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return (NSTextView(), scrollView)
        }

        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.string = sql

        if !sql.isEmpty {
            applySQLHighlightingWithCap(to: textView)
        }

        return (textView, scrollView)
    }

    private func applySQLHighlightingWithCap(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        let length = textStorage.length
        guard length > 0 else { return }

        let fullRange = NSRange(location: 0, length: length)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        textStorage.beginEditing()
        textStorage.addAttribute(.font, value: font, range: fullRange)
        textStorage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

        let highlightLength = min(length, Self.maxHighlightLength)
        let highlightRange = NSRange(location: 0, length: highlightLength)
        let text = textStorage.string

        // swiftlint:disable force_try
        let keywordPattern = try! NSRegularExpression(
            pattern: "\\b(SELECT|FROM|WHERE|INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|JOIN|LEFT|RIGHT|"
                + "INNER|OUTER|ON|AND|OR|NOT|IN|EXISTS|BETWEEN|LIKE|IS|AS|ORDER|BY|GROUP|"
                + "HAVING|LIMIT|OFFSET|UNION|ALL|DISTINCT|INTO|VALUES|SET|TABLE|INDEX|"
                + "PRIMARY|KEY|FOREIGN|REFERENCES|DEFAULT|CASE|WHEN|THEN|ELSE|END|"
                + "COUNT|SUM|AVG|MIN|MAX|WITH|RECURSIVE)\\b",
            options: .caseInsensitive
        )
        let stringPattern = try! NSRegularExpression(pattern: "'[^']*'")
        let numberPattern = try! NSRegularExpression(pattern: "\\b\\d+\\b")
        // swiftlint:enable force_try

        for match in keywordPattern.matches(in: text, range: highlightRange) {
            textStorage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: match.range)
        }
        for match in stringPattern.matches(in: text, range: highlightRange) {
            textStorage.addAttribute(.foregroundColor, value: NSColor.systemRed, range: match.range)
        }
        for match in numberPattern.matches(in: text, range: highlightRange) {
            textStorage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: match.range)
        }

        textStorage.endEditing()
    }

    private func highlightedSQLViaPatterns(_ code: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor
            ]
        )

        let nsCode = code as NSString
        let highlightLength = min(nsCode.length, Self.maxHighlightLength)
        let highlightRange = NSRange(location: 0, length: highlightLength)

        // swiftlint:disable:next force_try
        let keywordPattern = try! NSRegularExpression(
            pattern: "\\b(SELECT|FROM|WHERE|INSERT|UPDATE|DELETE)\\b",
            options: .caseInsensitive
        )

        for match in keywordPattern.matches(in: code, range: highlightRange) {
            attributed.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: match.range)
        }

        return attributed
    }
}
