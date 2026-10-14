//
//  HighlightedSQLTextView.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI
import TableProPluginKit

/// A code view, so it wears the editor theme: background, text and syntax. The colors are the palette's dynamic ones,
/// which resolve per appearance when the text view draws.
struct HighlightedSQLTextView: NSViewRepresentable {
    internal enum LineLayout: Equatable {
        case unwrapped
        case wrapped
        /// Wraps, and is as tall as its text up to `maxLines`; it scrolls vertically past that.
        case fitted(maxLines: Int)
    }

    internal enum Highlighting: Equatable {
        case engine
        case json
    }

    let sql: String
    var databaseType: DatabaseType = .mysql
    var highlighting: Highlighting = .engine
    /// A SwiftUI `.accessibilityIdentifier` lands on the representable's wrapper, not on the text
    /// view AppKit publishes, so the only way to name this element is to set it on the text view.
    var accessibilityIdentifier: String?
    var lineLayout: LineLayout = .unwrapped

    @ObservedObject private var themeEngine = ThemeEngine.shared

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.setAccessibilityLabel(String(localized: "Query preview"))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = themeEngine.editorFonts.font
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textColor = themeEngine.palette[.editorText]
        applyBackground(to: scrollView, textView: textView)
        applyLineLayout(to: scrollView, textView: textView)

        context.coordinator.redisplayOnThemeChange(scrollView)
        return scrollView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        guard case .fitted(let maxLines) = lineLayout,
              let width = proposal.width, width.isFinite,
              let textView = scrollView.documentView as? NSTextView else { return nil }
        let height = Self.fittedHeight(
            of: sql,
            font: themeEngine.editorFonts.font,
            width: width,
            inset: textView.textContainerInset,
            lineFragmentPadding: textView.textContainer?.lineFragmentPadding ?? 0,
            maxLines: maxLines
        )
        return CGSize(width: width, height: height)
    }

    internal static func fittedHeight(
        of text: String,
        font: NSFont,
        width: CGFloat,
        inset: NSSize,
        lineFragmentPadding: CGFloat,
        maxLines: Int
    ) -> CGFloat {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let container = NSTextContainer(size: NSSize(
            width: max(width - inset.width * 2, 1),
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = lineFragmentPadding
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        let textHeight = max(layoutManager.usedRect(for: container).height, lineHeight)
        return min(textHeight, CGFloat(max(maxLines, 1)) * lineHeight) + inset.height * 2
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let editorFont = themeEngine.editorFonts.font
        let fontChanged = textView.font != editorFont
        let textChanged = textView.string != sql

        if fontChanged {
            textView.font = editorFont
        }
        applyBackground(to: scrollView, textView: textView)

        if textChanged {
            textView.string = sql
        }

        /// The highlighting bakes a colour per range, so it is applied again whenever the theme, the
        /// editor font or the highlighting moves, not only when the query does.
        let highlightingChanged = context.coordinator.highlighting != highlighting
        guard !sql.isEmpty,
              textChanged || fontChanged || highlightingChanged || context.coordinator.revision != themeRevision else {
            return
        }
        context.coordinator.revision = themeRevision
        context.coordinator.highlighting = highlighting
        applyHighlighting(to: textView)
    }

    /// The scroll view paints the same color, so a short query never shows another background below its last line.
    private func applyBackground(to scrollView: NSScrollView, textView: NSTextView) {
        let background = themeEngine.palette[.editorBackground]
        guard textView.backgroundColor != background else { return }
        textView.backgroundColor = background
        scrollView.backgroundColor = background
    }

    private func applyLineLayout(to scrollView: NSScrollView, textView: NSTextView) {
        guard let container = textView.textContainer else { return }
        switch lineLayout {
        case .unwrapped:
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
        case .wrapped, .fitted:
            container.widthTracksTextView = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            scrollView.hasHorizontalScroller = false
            // A legacy scroller that stays up while the text fits narrows it below the fitted width.
            scrollView.autohidesScrollers = true
        }
    }

    private var themeRevision: Int {
        themeEngine.revision
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        var revision = -1
        var highlighting: Highlighting?
        private var themeCancellable: AnyCancellable?

        /// An Accent, Highlight or contrast change moves no published value, so nothing would otherwise redraw the
        /// system colors the text view holds.
        func redisplayOnThemeChange(_ scrollView: NSScrollView) {
            themeCancellable = AppEvents.shared.themeChanged
                .receive(on: RunLoop.main)
                .sink { [weak scrollView] _ in
                    scrollView?.needsDisplay = true
                    scrollView?.documentView?.needsDisplay = true
                }
        }
    }

    // MARK: - Syntax Highlighting

    private static let syntaxPatterns: [(regex: NSRegularExpression, slot: ThemeSlot)] = {
        var patterns: [(NSRegularExpression, ThemeSlot)] = []

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

        if let regex = try? NSRegularExpression(pattern: "'[^']*'", options: .caseInsensitive) {
            patterns.append((regex, .syntaxString))
        }

        if let regex = try? NSRegularExpression(pattern: "`[^`]*`", options: .caseInsensitive) {
            patterns.append((regex, .syntaxNull))
        }

        if let regex = try? NSRegularExpression(pattern: "\\b\\d+\\b", options: .caseInsensitive) {
            patterns.append((regex, .syntaxNumber))
        }

        return patterns
    }()

    private static let mqlPatterns: [(regex: NSRegularExpression, slot: ThemeSlot)] = {
        var patterns: [(NSRegularExpression, ThemeSlot)] = []

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

        if let regex = try? NSRegularExpression(pattern: "\\bdb\\.", options: []) {
            patterns.append((regex, .syntaxKeyword))
        }

        if let regex = try? NSRegularExpression(
            pattern: "\"\\$(gt|gte|lt|lte|eq|ne|in|nin|and|or|not|nor|exists|type|regex|options|"
                + "set|unset|inc|push|pull|addToSet|each|match|group|project|sort|limit|skip|"
                + "unwind|lookup|count|sum|avg|min|max|first|last|dateToString|toString|toInt|"
                + "oid|numberInt|numberLong|numberDouble|date|binary|timestamp|numberDecimal)\"",
            options: []
        ) {
            patterns.append((regex, .syntaxType))
        }

        if let regex = try? NSRegularExpression(pattern: "\"[^\"]*\"", options: []) {
            patterns.append((regex, .syntaxString))
        }

        if let regex = try? NSRegularExpression(pattern: "\\b\\d+\\.?\\d*\\b", options: []) {
            patterns.append((regex, .syntaxNumber))
        }

        if let regex = try? NSRegularExpression(pattern: "\\b(true|false|null)\\b", options: []) {
            patterns.append((regex, .syntaxNull))
        }

        return patterns
    }()

    /// The JSON editor's colors: keys and values both as strings. Strings go last so a digit or a literal inside one stays string-colored.
    private static let jsonPatterns: [(regex: NSRegularExpression, slot: ThemeSlot)] = {
        let sources: [(pattern: String, slot: ThemeSlot)] = [
            (#"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, .syntaxNumber),
            (#"\b(?:true|false|null)\b"#, .syntaxNull),
            (#""(?:[^"\\]|\\.)*""#, .syntaxString),
        ]
        return sources.compactMap { source in
            (try? NSRegularExpression(pattern: source.pattern)).map { (regex: $0, slot: source.slot) }
        }
    }()

    private var activePatterns: [(regex: NSRegularExpression, slot: ThemeSlot)] {
        if highlighting == .json { return Self.jsonPatterns }
        switch PluginManager.shared.editorLanguage(for: databaseType) {
        case .javascript:
            return Self.mqlPatterns
        default:
            return Self.syntaxPatterns
        }
    }

    private func applyHighlighting(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        guard textStorage.length > 0 else { return }

        let fullRange = NSRange(location: 0, length: textStorage.length)

        textStorage.beginEditing()

        let font = ThemeEngine.shared.editorFonts.font
        textStorage.addAttribute(.font, value: font, range: fullRange)
        textStorage.addAttribute(.foregroundColor, value: ThemeEngine.shared.palette[.editorText], range: fullRange)

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
