
//
//  TPSyntaxHighlighter.swift
//  TablePro
//
//  SQL syntax highlighter using Apple's recommended temporary attributes pattern.
//  Uses a character-by-character scanner for accurate tokenization with O(1) access
//  via NSString.character(at:). Applies colors via NSLayoutManager.addTemporaryAttribute
//  so highlighting never interferes with undo, copy/paste, or cursor positioning.
//

import AppKit
import os

final class TPSyntaxHighlighter: NSObject {

    // MARK: - Constants

    private static let logger = Logger(subsystem: "com.TablePro", category: "TPSyntaxHighlighter")

    /// Skip highlighting for files larger than 2MB
    private static let maxFileSize = 2_000_000

    /// Don't highlight individual lines longer than 10,000 characters
    private static let maxLineLength = 10_000

    /// Padding around visible range to avoid flicker at edges
    private static let viewportPadding = 2000

    /// Debounce interval for text changes (~1 frame at 60fps)
    private static let debounceInterval: TimeInterval = 0.016

    // MARK: - Properties

    private var theme: TPEditorTheme
    private weak var textView: NSTextView?
    private var highlightWorkItem: DispatchWorkItem?
    private var scrollObserver: NSObjectProtocol?

    private static let sqlKeywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "CREATE", "DROP",
        "ALTER", "JOIN", "ON", "AND", "OR", "NOT", "IN", "IS", "NULL", "AS", "SET",
        "INTO", "VALUES", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET",
        "UNION", "ALL", "DISTINCT", "BETWEEN", "LIKE", "EXISTS", "CASE", "WHEN",
        "THEN", "ELSE", "END", "BEGIN", "COMMIT", "ROLLBACK", "INDEX", "TABLE",
        "VIEW", "TRIGGER", "PROCEDURE", "FUNCTION", "DATABASE", "SCHEMA", "GRANT",
        "REVOKE", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "CONSTRAINT", "DEFAULT",
        "CHECK", "UNIQUE", "AUTO_INCREMENT", "CASCADE", "INNER", "LEFT", "RIGHT",
        "OUTER", "CROSS", "FULL", "ASC", "DESC", "WITH", "RECURSIVE", "TEMP",
        "TEMPORARY", "IF", "EXPLAIN", "ANALYZE", "SHOW", "USE", "DESCRIBE",
        "TRUNCATE", "RENAME", "ADD", "COLUMN", "MODIFY", "TYPE", "REPLACE",
        "RETURNING", "CONFLICT", "EXCEPT", "INTERSECT", "FETCH", "NEXT", "ROWS",
        "ONLY", "WINDOW", "PARTITION", "OVER", "RANGE", "UNBOUNDED", "PRECEDING",
        "FOLLOWING", "CURRENT", "ROW", "TRUE", "FALSE", "COUNT", "SUM", "AVG",
        "MIN", "MAX", "COALESCE", "NULLIF", "CAST"
    ]

    // MARK: - Init

    init(theme: TPEditorTheme) {
        self.theme = theme
        super.init()
    }

    deinit {
        uninstall()
    }

    // MARK: - Public API

    func install(on textView: NSTextView) {
        self.textView = textView

        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.highlightVisibleRange()
        }
    }

    func uninstall() {
        highlightWorkItem?.cancel()
        highlightWorkItem = nil

        if let observer = scrollObserver {
            NotificationCenter.default.removeObserver(observer)
            scrollObserver = nil
        }

        textView = nil
    }

    func updateTheme(_ theme: TPEditorTheme) {
        self.theme = theme
        highlightVisibleRange()
    }

    /// Called from the coordinator's textDidChange(_:). Debounces and re-highlights.
    func textDidChange(_ notification: Notification) {
        scheduleHighlight()
    }

    /// Highlights the currently visible range. Called on scroll, initial load, and theme changes.
    func highlightVisibleRange() {
        guard let textView = textView,
              let layoutManager = textView.layoutManager else { return }

        let nsString = textView.string as NSString
        let length = nsString.length

        guard length > 0, length <= Self.maxFileSize else {
            if length > Self.maxFileSize {
                Self.logger.info("Skipping highlighting: file too large (\(length) chars)")
            }
            return
        }

        guard let visibleRange = visibleCharacterRange() else { return }

        let highlightRange = expandToLineBoundaries(visibleRange, in: nsString)
        highlight(in: highlightRange, string: nsString, layoutManager: layoutManager)
    }

    // MARK: - Private — Scheduling

    private func scheduleHighlight() {
        highlightWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.highlightVisibleRange()
        }
        highlightWorkItem = workItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.debounceInterval,
            execute: workItem
        )
    }

    // MARK: - Private — Highlighting

    private func highlight(in range: NSRange, string: NSString, layoutManager: NSLayoutManager) {
        guard range.length > 0, NSMaxRange(range) <= string.length else { return }

        // Clear existing temporary attributes in this range
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)

        // Scan tokens and apply colors
        let tokens = scanTokens(in: string, range: range)
        for token in tokens {
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: token.color,
                forCharacterRange: token.range
            )
        }
    }

    // MARK: - Private — Scanner

    /// Scans the given range of the string and returns colored token ranges.
    /// Uses NSString.character(at:) for O(1) character access throughout.
    private func scanTokens(in string: NSString, range: NSRange) -> [(range: NSRange, color: NSColor)] {
        var tokens: [(range: NSRange, color: NSColor)] = []
        let end = NSMaxRange(range)
        var i = range.location

        while i < end {
            let ch = string.character(at: i)

            // Single-line comment: -- to end of line
            if ch == asciiDash, i + 1 < end, string.character(at: i + 1) == asciiDash {
                let start = i
                i += 2
                while i < end {
                    let c = string.character(at: i)
                    if c == asciiNewline || c == asciiCarriageReturn {
                        break
                    }
                    i += 1
                }
                let tokenRange = NSRange(location: start, length: i - start)
                if tokenRange.length <= Self.maxLineLength {
                    tokens.append((range: tokenRange, color: theme.comment))
                }
                continue
            }

            // Multi-line comment: /* ... */
            if ch == asciiSlash, i + 1 < end, string.character(at: i + 1) == asciiStar {
                let start = i
                i += 2
                while i + 1 < end {
                    if string.character(at: i) == asciiStar, string.character(at: i + 1) == asciiSlash {
                        i += 2
                        break
                    }
                    i += 1
                }
                // Handle unterminated comment — consume to end of range
                if i <= start + 2, i < end {
                    i = end
                }
                let tokenRange = NSRange(location: start, length: i - start)
                tokens.append((range: tokenRange, color: theme.comment))
                continue
            }

            // Single-quoted string
            if ch == asciiSingleQuote {
                let tokenRange = scanQuotedString(in: string, from: i, end: end, quote: asciiSingleQuote)
                tokens.append((range: tokenRange, color: theme.string))
                i = NSMaxRange(tokenRange)
                continue
            }

            // Double-quoted string (identifier in SQL, but highlighted as string)
            if ch == asciiDoubleQuote {
                let tokenRange = scanQuotedString(in: string, from: i, end: end, quote: asciiDoubleQuote)
                tokens.append((range: tokenRange, color: theme.string))
                i = NSMaxRange(tokenRange)
                continue
            }

            // Backtick-quoted identifier
            if ch == asciiBacktick {
                let tokenRange = scanQuotedString(in: string, from: i, end: end, quote: asciiBacktick)
                tokens.append((range: tokenRange, color: theme.string))
                i = NSMaxRange(tokenRange)
                continue
            }

            // Numbers: digits, optionally followed by decimal point, scientific notation
            if isDigit(ch) || (ch == asciiDot && i + 1 < end && isDigit(string.character(at: i + 1))) {
                let start = i
                i = scanNumber(in: string, from: i, end: end)
                tokens.append((range: NSRange(location: start, length: i - start), color: theme.number))
                continue
            }

            // Variables: @variable, :parameter, $1
            if ch == asciiAt || ch == asciiColon || ch == asciiDollar {
                let start = i
                i += 1
                // Allow leading @ or @@ for MySQL system variables
                if ch == asciiAt, i < end, string.character(at: i) == asciiAt {
                    i += 1
                }
                while i < end, isWordChar(string.character(at: i)) {
                    i += 1
                }
                if i > start + 1 {
                    tokens.append((range: NSRange(location: start, length: i - start), color: theme.variable))
                    continue
                }
                // Single symbol without following word chars — skip
                continue
            }

            // Words: keywords or identifiers
            if isWordStart(ch) {
                let start = i
                i += 1
                while i < end, isWordChar(string.character(at: i)) {
                    i += 1
                }
                let wordLength = i - start
                if wordLength <= Self.maxLineLength {
                    let word = string.substring(with: NSRange(location: start, length: wordLength))
                    if isKeyword(word) {
                        tokens.append((range: NSRange(location: start, length: wordLength), color: theme.keyword))
                    }
                }
                continue
            }

            // Skip any other character
            i += 1
        }

        return tokens
    }

    /// Scans a quoted string starting at `from` (the opening quote character).
    /// Handles escaped quotes (doubled quote or backslash-escaped).
    private func scanQuotedString(in string: NSString, from start: Int, end: Int, quote: unichar) -> NSRange {
        var i = start + 1
        while i < end {
            let ch = string.character(at: i)
            if ch == asciiBackslash {
                // Skip escaped character
                i += 2
                continue
            }
            if ch == quote {
                // Check for doubled quote (e.g., '' in SQL)
                if i + 1 < end, string.character(at: i + 1) == quote {
                    i += 2
                    continue
                }
                // End of quoted string
                i += 1
                return NSRange(location: start, length: i - start)
            }
            i += 1
        }
        // Unterminated string — highlight to end of scanned range
        return NSRange(location: start, length: i - start)
    }

    /// Scans a numeric literal (integer, decimal, scientific notation).
    private func scanNumber(in string: NSString, from start: Int, end: Int) -> Int {
        var i = start

        // Integer part (may be empty if we started with '.')
        while i < end, isDigit(string.character(at: i)) {
            i += 1
        }

        // Decimal part
        if i < end, string.character(at: i) == asciiDot {
            i += 1
            while i < end, isDigit(string.character(at: i)) {
                i += 1
            }
        }

        // Scientific notation: e or E, optional +/-
        if i < end {
            let ch = string.character(at: i)
            if ch == asciiLowerE || ch == asciiUpperE {
                i += 1
                if i < end {
                    let sign = string.character(at: i)
                    if sign == asciiPlus || sign == asciiDash {
                        i += 1
                    }
                }
                while i < end, isDigit(string.character(at: i)) {
                    i += 1
                }
            }
        }

        return i
    }

    // MARK: - Private — Keyword Matching

    private func isKeyword(_ word: String) -> Bool {
        Self.sqlKeywords.contains(word.uppercased())
    }

    // MARK: - Private — Viewport Helpers

    private func visibleCharacterRange() -> NSRange? {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }

        let nsString = textView.string as NSString
        let totalLength = nsString.length
        guard totalLength > 0 else { return nil }

        let visibleRect = textView.visibleRect
        guard !visibleRect.isEmpty else {
            // No visible rect yet — highlight the beginning
            return NSRange(location: 0, length: min(totalLength, Self.viewportPadding * 2))
        }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        var charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Add padding for context at boundaries
        let paddedStart = max(0, charRange.location - Self.viewportPadding)
        let paddedEnd = min(totalLength, NSMaxRange(charRange) + Self.viewportPadding)
        charRange = NSRange(location: paddedStart, length: paddedEnd - paddedStart)

        return charRange
    }

    /// Expands the range to cover complete lines so tokens at line boundaries are not split.
    private func expandToLineBoundaries(_ range: NSRange, in string: NSString) -> NSRange {
        let length = string.length
        guard length > 0, range.length > 0 else { return range }

        // Find start of the line containing range.location
        var lineStart = range.location
        while lineStart > 0 {
            let ch = string.character(at: lineStart - 1)
            if ch == asciiNewline || ch == asciiCarriageReturn {
                break
            }
            lineStart -= 1
        }

        // Find end of the line containing NSMaxRange(range)
        var lineEnd = NSMaxRange(range)
        while lineEnd < length {
            let ch = string.character(at: lineEnd)
            if ch == asciiNewline || ch == asciiCarriageReturn {
                lineEnd += 1
                break
            }
            lineEnd += 1
        }

        return NSRange(location: lineStart, length: lineEnd - lineStart)
    }

    // MARK: - Private — Character Classification

    private func isDigit(_ ch: unichar) -> Bool {
        ch >= asciiZero && ch <= asciiNine
    }

    private func isWordStart(_ ch: unichar) -> Bool {
        (ch >= asciiLowerA && ch <= asciiLowerZ)
            || (ch >= asciiUpperA && ch <= asciiUpperZ)
            || ch == asciiUnderscore
    }

    private func isWordChar(_ ch: unichar) -> Bool {
        isWordStart(ch) || isDigit(ch)
    }

    // MARK: - Private — ASCII Constants

    private let asciiNewline: unichar = 0x0A
    private let asciiCarriageReturn: unichar = 0x0D
    private let asciiSpace: unichar = 0x20
    private let asciiDot: unichar = 0x2E
    private let asciiSlash: unichar = 0x2F
    private let asciiStar: unichar = 0x2A
    private let asciiDash: unichar = 0x2D
    private let asciiSingleQuote: unichar = 0x27
    private let asciiDoubleQuote: unichar = 0x22
    private let asciiBacktick: unichar = 0x60
    private let asciiBackslash: unichar = 0x5C
    private let asciiAt: unichar = 0x40
    private let asciiColon: unichar = 0x3A
    private let asciiDollar: unichar = 0x24
    private let asciiPlus: unichar = 0x2B
    private let asciiZero: unichar = 0x30
    private let asciiNine: unichar = 0x39
    private let asciiLowerA: unichar = 0x61
    private let asciiLowerZ: unichar = 0x7A
    private let asciiUpperA: unichar = 0x41
    private let asciiUpperZ: unichar = 0x5A
    private let asciiUnderscore: unichar = 0x5F
    private let asciiLowerE: unichar = 0x65
    private let asciiUpperE: unichar = 0x45
}
