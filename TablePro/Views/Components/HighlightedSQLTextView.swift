//
//  HighlightedSQLTextView.swift
//  TablePro
//
//  Read-only NSTextView with regex-based SQL syntax highlighting.
//  Used for query previews in the history panel.
//

import AppKit
import SwiftUI
import TableProPluginKit

/// Read-only text view that applies SQL/MQL syntax highlighting via regex
struct HighlightedSQLTextView: NSViewRepresentable {
    let sql: String
    var fontSize: CGFloat = 13
    var databaseType: DatabaseType = .mysql

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        // Configure text view
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.labelColor

        // Disable line wrapping
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Update font if changed
        if let currentFont = textView.font, currentFont.pointSize != fontSize {
            textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            if !textView.string.isEmpty {
                applyHighlighting(to: textView)
            }
        }

        // Update text if changed
        if textView.string != sql {
            textView.string = sql
            if !sql.isEmpty {
                applyHighlighting(to: textView)
            }
        }
    }

    // MARK: - Syntax Highlighting

    // MARK: - Pre-compiled Syntax Patterns

    private static let syntaxPatterns: [(regex: NSRegularExpression, color: NSColor)] = {
        var patterns: [(NSRegularExpression, NSColor)] = []

        // SQL Keywords (blue) — single alternation regex for all keywords
        let keywords = [
            "CREATE", "TABLE", "PRIMARY", "KEY", "FOREIGN", "REFERENCES",
            "NOT", "NULL", "DEFAULT", "UNIQUE", "INDEX", "AUTO_INCREMENT",
            "ON", "DELETE", "UPDATE", "CASCADE", "RESTRICT", "SET",
            "INT", "INTEGER", "VARCHAR", "CHAR", "TEXT", "TIMESTAMP", "DATETIME",
            "SELECT", "FROM", "WHERE", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER",
            "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "INSERT", "INTO",
            "VALUES", "DROP", "ALTER", "ADD", "COLUMN", "IF", "EXISTS", "AS",
            "AND", "OR", "IN", "LIKE", "BETWEEN", "IS", "DISTINCT", "COUNT",
            "SUM", "AVG", "MIN", "MAX", "CASE", "WHEN", "THEN", "ELSE", "END",
            "UNION", "ALL", "WITH", "RECURSIVE"
        ]
        let keywordPattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
        if let regex = try? NSRegularExpression(pattern: keywordPattern, options: .caseInsensitive) {
            patterns.append((regex, .systemBlue))
        }

        // Strings (red)
        if let regex = try? NSRegularExpression(pattern: "'[^']*'", options: .caseInsensitive) {
            patterns.append((regex, .systemRed))
        }

        // Backticks (orange)
        if let regex = try? NSRegularExpression(pattern: "`[^`]*`", options: .caseInsensitive) {
            patterns.append((regex, .systemOrange))
        }

        // Numbers (purple)
        if let regex = try? NSRegularExpression(pattern: "\\b\\d+\\b", options: .caseInsensitive) {
            patterns.append((regex, .systemPurple))
        }

        return patterns
    }()

    // MARK: - Pre-compiled MQL Syntax Patterns

    private static let mqlPatterns: [(regex: NSRegularExpression, color: NSColor)] = {
        var patterns: [(NSRegularExpression, NSColor)] = []

        // MongoDB methods (blue) — single alternation regex for all methods
        let methods = [
            "find", "findOne", "insertOne", "insertMany", "updateOne", "updateMany",
            "deleteOne", "deleteMany", "aggregate", "countDocuments", "estimatedDocumentCount",
            "distinct", "createIndex", "dropIndex", "sort", "limit", "skip", "project",
            "match", "group", "unwind", "lookup", "replaceOne", "drop"
        ]
        let methodPattern = "\\.(" + methods.joined(separator: "|") + ")\\s*\\("
        if let regex = try? NSRegularExpression(pattern: methodPattern, options: []) {
            patterns.append((regex, .systemBlue))
        }

        // db. prefix (blue)
        if let regex = try? NSRegularExpression(pattern: "\\bdb\\.", options: []) {
            patterns.append((regex, .systemBlue))
        }

        // MongoDB operators $gt, $lt, $in, etc. (teal)
        if let regex = try? NSRegularExpression(
            pattern: "\"\\$(gt|gte|lt|lte|eq|ne|in|nin|and|or|not|nor|exists|type|regex|options|"
                + "set|unset|inc|push|pull|addToSet|each|match|group|project|sort|limit|skip|"
                + "unwind|lookup|count|sum|avg|min|max|first|last|dateToString|toString|toInt|"
                + "oid|numberInt|numberLong|numberDouble|date|binary|timestamp|numberDecimal)\"",
            options: []
        ) {
            patterns.append((regex, .systemTeal))
        }

        // Strings (red)
        if let regex = try? NSRegularExpression(pattern: "\"[^\"]*\"", options: []) {
            patterns.append((regex, .systemRed))
        }

        // Numbers (purple)
        if let regex = try? NSRegularExpression(pattern: "\\b\\d+\\.?\\d*\\b", options: []) {
            patterns.append((regex, .systemPurple))
        }

        // Booleans and null (orange)
        if let regex = try? NSRegularExpression(pattern: "\\b(true|false|null)\\b", options: []) {
            patterns.append((regex, .systemOrange))
        }

        return patterns
    }()

    private func applyHighlighting(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        guard textStorage.length > 0 else { return }

        let fullRange = NSRange(location: 0, length: textStorage.length)

        textStorage.beginEditing()

        // Reset to base style
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textStorage.addAttribute(.font, value: font, range: fullRange)
        textStorage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

        // Apply pre-compiled patterns
        let activePatterns: [(regex: NSRegularExpression, color: NSColor)]
        switch PluginManager.shared.editorLanguage(for: databaseType) {
        case .javascript:
            activePatterns = Self.mqlPatterns
        default:
            activePatterns = Self.syntaxPatterns
        }
        let text = textStorage.string
        let maxHighlightLength = 10_000
        let highlightRange: NSRange
        if textStorage.length > maxHighlightLength {
            highlightRange = NSRange(location: 0, length: maxHighlightLength)
        } else {
            highlightRange = fullRange
        }
        for (regex, color) in activePatterns {
            let matches = regex.matches(in: text, options: [], range: highlightRange)
            for match in matches {
                textStorage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }

        textStorage.endEditing()
    }
}
