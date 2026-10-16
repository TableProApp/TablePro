//
//  CodeBlockHighlighter.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProEditorKit
import TableProGrammars
import TableProTextEngine

/// Syntax colors for a chat code block from the editor's own grammar and theme, with no editor behind them.
///
/// A code block used to embed a whole `SourceEditor`, which a transcript row built each time it scrolled in. The
/// block only ever shows code, so it needs the editor's colors, not the editor. The colors are worked out away from
/// the main actor, once per block and theme, and the block shows its plain text until they arrive. Color and weight
/// do not move a monospaced line, so the row keeps its height unless the code holds an invisible character to mark.
@MainActor
internal enum CodeBlockHighlighter {
    /// Past this many UTF-16 units only the lines before it are colored, as everywhere the app highlights a string
    /// that can hold a whole dump on one line.
    nonisolated internal static let maximumHighlightedLength = 10_000

    private final class Entry {
        let text: AttributedString

        init(_ text: AttributedString) {
            self.text = text
        }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 256
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    /// What a block's colors depend on, or nil when there is no code. The theme change is part of it because the
    /// colors are the theme's objects of the moment: SwiftUI holds a `Color(nsColor:)` by identity, and a theme or
    /// appearance change has to produce new ones.
    internal static func key(
        for code: String,
        language: CodeLanguage,
        font: NSFont,
        themeEngine: ThemeEngine = .shared
    ) -> String? {
        guard !code.isEmpty else { return nil }
        let change = themeEngine.change
        return "\(change.revision):\(change.generation):\(font.fontName):\(font.pointSize):\(language.id)\n\(code)"
    }

    internal static func cachedCode(forKey key: String) -> AttributedString? {
        cache.object(forKey: key as NSString)?.text
    }

    internal static func highlightedCode(
        _ code: String,
        language: CodeLanguage,
        font: NSFont,
        key: String,
        themeEngine: ThemeEngine = .shared
    ) async -> AttributedString {
        if let cached = cachedCode(forKey: key) {
            return cached
        }
        let markup = await markup(of: code, language: language)
        let text = attributed(code, markup: markup, font: font, theme: themeEngine.makeEditorTheme())
        cache.setObject(Entry(text), forKey: key as NSString, cost: (key as NSString).length)
        return text
    }

    /// Captures and colors in one call, against a theme the caller chose.
    internal static func highlight(
        _ code: String,
        language: CodeLanguage,
        font: NSFont,
        theme: EditorTheme
    ) async -> AttributedString {
        attributed(code, markup: await markup(of: code, language: language), font: font, theme: theme)
    }

    /// What the code holds beyond its characters: the grammar's captures, and the invisible characters a reader has
    /// to see before running it, as the editor marks them. Found away from the main actor, since both grow with the
    /// code.
    internal struct Markup: Sendable {
        let highlights: [HighlightRange]
        let specialCharacters: [ClassifiedSpecialCharacter]
    }

    /// The grammar's captures over the whole lines before the cap. `HighlightedSQLTextView` colors with these too,
    /// so a statement reads the same in a chat block, a preview and the editor.
    nonisolated internal static func captures(in code: String, language: CodeLanguage) -> [HighlightRange] {
        let nsCode = code as NSString
        let highlightedLength = nsCode.length > maximumHighlightedLength
            ? nsCode.lineRange(for: NSRange(location: maximumHighlightedLength, length: 0)).location
            : nsCode.length
        guard highlightedLength > 0, language.id != CodeLanguage.default.id else { return [] }
        let source = highlightedLength == nsCode.length ? code : nsCode.substring(to: highlightedLength)
        return TreeSitterClient.highlightRanges(in: source, language: language) ?? []
    }

    @concurrent
    nonisolated private static func markup(of code: String, language: CodeLanguage) async -> Markup {
        let nsCode = code as NSString
        let highlights = captures(in: code, language: language)
        var specialCharacters: [ClassifiedSpecialCharacter] = []
        var index = 0
        while index < nsCode.length {
            if let classified = SpecialCharacter.classify(in: nsCode, at: index) {
                specialCharacters.append(classified)
                index = NSMaxRange(classified.range)
            } else {
                index += 1
            }
        }
        return Markup(highlights: highlights, specialCharacters: specialCharacters)
    }

    /// The colors and bold weights the editor gives each capture, as SwiftUI attributes so `Text` draws them on
    /// every macOS version, with invisible characters marked the way error messages mark them. Text no capture covers
    /// takes the base color the caller sets.
    internal static func attributed(
        _ code: String,
        markup: Markup,
        font: NSFont,
        theme: EditorTheme
    ) -> AttributedString {
        var result = AttributedString(code)
        for highlight in markup.highlights {
            guard let runRange = Range(highlight.range, in: result) else { continue }
            result[runRange].foregroundColor = Color(nsColor: theme.colorFor(highlight.capture))
            let runFont = theme.fontFor(for: highlight.capture, from: font)
            if runFont != font {
                result[runRange].font = Font(runFont)
            }
        }
        /// From the end, so each replacement leaves the ranges before it where they were.
        for special in markup.specialCharacters.reversed() {
            guard let range = Range(special.range, in: result) else { continue }
            switch special.character {
            case .marker(let label):
                var mark = AttributedString("<\(label)>")
                mark.foregroundColor = RevealedText.markColor
                mark.backgroundColor = RevealedText.markBackground
                result.replaceSubrange(range, with: mark)
            case .blankSpace:
                result[range].backgroundColor = RevealedText.blankSpaceBackground
            }
        }
        return result
    }
}
