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
    var databaseType: DatabaseType = .mysql
    /// A SwiftUI `.accessibilityIdentifier` lands on the representable's wrapper, not on the text
    /// view AppKit publishes, so the only way to name this element is to set it on the text view.
    var accessibilityIdentifier: String?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.setAccessibilityLabel(String(localized: "Query preview"))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = ThemeEngine.shared.editorFonts.font
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.backgroundColor = ThemeEngine.shared.palette[.editorBackground]
        textView.textColor = ThemeEngine.shared.palette[.editorText]

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

        let editorFont = ThemeEngine.shared.editorFonts.font
        let fontChanged = textView.font != editorFont
        let textChanged = textView.string != sql

        if fontChanged {
            textView.font = editorFont
        }
        textView.backgroundColor = ThemeEngine.shared.palette[.editorBackground]
        textView.textColor = ThemeEngine.shared.palette[.editorText]

        if textChanged {
            textView.string = sql
        }

        /// The highlighting bakes a colour per range, so it is applied again whenever the theme or
        /// the editor font moves, not only when the query does.
        guard !sql.isEmpty, textChanged || fontChanged || context.coordinator.revision != themeRevision else {
            return
        }
        context.coordinator.revision = themeRevision
        applyHighlighting(to: textView)
    }

    private var themeRevision: Int {
        ThemeEngine.shared.revision
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var revision = -1
    }

    // MARK: - Syntax Highlighting

    // MARK: - Pre-compiled Syntax Patterns

    private static let syntaxPatterns: [(regex: NSRegularExpression, slot: ThemeSlot)] = {
        var patterns: [(NSRegularExpression, ThemeSlot)] = []

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
            patterns.append((regex, .syntaxKeyword))
        }

        // Strings (red)
        if let regex = try? NSRegularExpression(pattern: "'[^']*'", options: .caseInsensitive) {
            patterns.append((regex, .syntaxString))
        }

        // Backticks (orange)
        if let regex = try? NSRegularExpression(pattern: "`[^`]*`", options: .caseInsensitive) {
            patterns.append((regex, .syntaxNull))
        }

        // Numbers (purple)
        if let regex = try? NSRegularExpression(pattern: "\\b\\d+\\b", options: .caseInsensitive) {
            patterns.append((regex, .syntaxNumber))
        }

        return patterns
    }()

    // MARK: - Pre-compiled MQL Syntax Patterns

    private static let mqlPatterns: [(regex: NSRegularExpression, slot: ThemeSlot)] = {
        var patterns: [(NSRegularExpression, ThemeSlot)] = []

        // MongoDB methods (blue) — single alternation regex for all methods
        let methods = [
            "find", "findOne", "insertOne", "insertMany", "updateOne", "updateMany",
            "deleteOne", "deleteMany", "aggregate", "countDocuments", "estimatedDocumentCount",
            "distinct", "createIndex", "dropIndex", "sort", "limit", "skip", "project",
            "match", "group", "unwind", "lookup", "replaceOne", "drop"
        ]
        let methodPattern = "\\.(" + methods.joined(separator: "|") + ")\\s*\\("
        if let regex = try? NSRegularExpression(pattern: methodPattern, options: []) {
            patterns.append((regex, .syntaxKeyword))
        }

        // db. prefix (blue)
        if let regex = try? NSRegularExpression(pattern: "\\bdb\\.", options: []) {
            patterns.append((regex, .syntaxKeyword))
        }

        // MongoDB operators $gt, $lt, $in, etc. (teal)
        if let regex = try? NSRegularExpression(
            pattern: "\"\\$(gt|gte|lt|lte|eq|ne|in|nin|and|or|not|nor|exists|type|regex|options|"
                + "set|unset|inc|push|pull|addToSet|each|match|group|project|sort|limit|skip|"
                + "unwind|lookup|count|sum|avg|min|max|first|last|dateToString|toString|toInt|"
                + "oid|numberInt|numberLong|numberDouble|date|binary|timestamp|numberDecimal)\"",
            options: []
        ) {
            patterns.append((regex, .syntaxType))
        }

        // Strings (red)
        if let regex = try? NSRegularExpression(pattern: "\"[^\"]*\"", options: []) {
            patterns.append((regex, .syntaxString))
        }

        // Numbers (purple)
        if let regex = try? NSRegularExpression(pattern: "\\b\\d+\\.?\\d*\\b", options: []) {
            patterns.append((regex, .syntaxNumber))
        }

        // Booleans and null (orange)
        if let regex = try? NSRegularExpression(pattern: "\\b(true|false|null)\\b", options: []) {
            patterns.append((regex, .syntaxNull))
        }

        return patterns
    }()

    private func applyHighlighting(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        guard textStorage.length > 0 else { return }

        let fullRange = NSRange(location: 0, length: textStorage.length)

        textStorage.beginEditing()

        // Reset to base style
        let font = ThemeEngine.shared.editorFonts.font
        textStorage.addAttribute(.font, value: font, range: fullRange)
        textStorage.addAttribute(.foregroundColor, value: ThemeEngine.shared.palette[.editorText], range: fullRange)

        // Apply pre-compiled patterns
        let activePatterns: [(regex: NSRegularExpression, slot: ThemeSlot)]
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
        let palette = ThemeEngine.shared.palette

        for (regex, slot) in activePatterns {
            let matches = regex.matches(in: text, options: [], range: highlightRange)
            for match in matches {
                textStorage.addAttribute(.foregroundColor, value: palette[slot], range: match.range)
            }
        }

        textStorage.endEditing()
    }
}
