//
//  TreeSitterClient+Temporary.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 7/24/25.
//

import AppKit
import SwiftTreeSitter
import TableProGrammars

public extension TreeSitterClient {
    /// The captures the editor's grammar finds in `string`, for a view that shows code it never edits and applies
    /// its own attributes. Safe away from the main thread: each call makes its own parser, and the compiled queries
    /// are behind a lock.
    static func highlightRanges(in string: String, language: CodeLanguage) -> [HighlightRange]? {
        guard let parserLanguage = language.language, let query = HighlightQueries.shared.query(for: language.id) else {
            return nil
        }

        do {
            let parser = Parser()
            try parser.setLanguage(parserLanguage)
            guard let syntaxTree = parser.parse(string) else {
                return nil
            }
            let queryCursor = query.execute(in: syntaxTree)
            var ranges: [NSRange: Int] = [:]
            return queryCursor
                .resolve(with: .init(string: string))
                .flatMap { $0.captures }
                .reversed() // SwiftTreeSitter returns captures in the reverse order of what we need to filter with.
                .compactMap { capture in
                    let range = capture.range
                    let index = capture.index

                    // Lower indexed captures are favored over higher, this is why we reverse it above
                    if let existingLevel = ranges[range], existingLevel <= index {
                        return nil
                    }

                    guard let captureName = CaptureName.fromString(capture.name) else {
                        return nil
                    }

                    // Update the filter level to the current index since it's lower and a 'valid' capture
                    ranges[range] = index

                    return HighlightRange(range: range, capture: captureName)
                }
        } catch {
            return nil
        }
    }

    /// `string` with the theme's color and weight on each range the grammar captures.
    static func quickHighlight(
        string: String,
        theme: EditorTheme,
        font: NSFont,
        language: CodeLanguage
    ) -> NSAttributedString? {
        guard let highlights = highlightRanges(in: string, language: language) else {
            return nil
        }

        let string = NSMutableAttributedString(string: string)

        for highlight in highlights {
            string.setAttributes(
                [
                    .font: theme.fontFor(for: highlight.capture, from: font),
                    .foregroundColor: theme.colorFor(highlight.capture)
                ],
                range: highlight.range
            )
        }

        return string
    }
}
