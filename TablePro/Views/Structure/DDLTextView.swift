//
//  DDLTextView.swift
//  TablePro
//
//  Simple AppKit text view for displaying DDL with syntax highlighting
//

import AppKit
import SwiftUI

/// Simple AppKit-based text view for DDL display - NO LINE NUMBERS FOR NOW
struct DDLTextView: NSViewRepresentable {
    let ddl: String
    @Binding var fontSize: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        // Configure text view - SIMPLE SETUP
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.labelColor

        // Disable line wrapping
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Update font if changed
        if let currentFont = textView.font, currentFont.pointSize != fontSize {
            textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            if !textView.string.isEmpty {
                applyBasicSyntaxHighlighting(to: textView, fontSize: fontSize)
            }
        }

        // Update text if changed
        if textView.string != ddl {
            textView.string = ddl
            if !ddl.isEmpty {
                applyBasicSyntaxHighlighting(to: textView, fontSize: fontSize)
            }
        }
    }

    // MARK: - Pre-compiled Syntax Patterns

    private static let syntaxPatterns: [(regex: NSRegularExpression, color: NSColor)] = {
        var patterns: [(NSRegularExpression, NSColor)] = []

        // SQL Keywords (blue) — single alternation regex for all keywords
        let keywords = [
            "CREATE", "TABLE", "PRIMARY", "KEY", "FOREIGN", "REFERENCES",
            "NOT", "NULL", "DEFAULT", "UNIQUE", "INDEX", "AUTO_INCREMENT",
            "ON", "DELETE", "UPDATE", "CASCADE", "RESTRICT", "SET",
            "INT", "INTEGER", "VARCHAR", "CHAR", "TEXT", "TIMESTAMP", "DATETIME"
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

    /// Apply basic SQL syntax highlighting
    private func applyBasicSyntaxHighlighting(to textView: NSTextView, fontSize: CGFloat) {
        guard let textStorage = textView.textStorage else { return }
        guard textStorage.length > 0 else { return }

        let fullRange = NSRange(location: 0, length: textStorage.length)

        textStorage.beginEditing()

        // Reset to base style
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textStorage.addAttribute(.font, value: font, range: fullRange)
        textStorage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

        // Apply pre-compiled patterns (cap to 10k chars for large DDL safety)
        let text = textStorage.string
        let highlightLength = min(textStorage.length, 10_000)
        let highlightRange = NSRange(location: 0, length: highlightLength)
        for (regex, color) in Self.syntaxPatterns {
            let matches = regex.matches(in: text, options: [], range: highlightRange)
            for match in matches {
                textStorage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }

        textStorage.endEditing()
    }
}
