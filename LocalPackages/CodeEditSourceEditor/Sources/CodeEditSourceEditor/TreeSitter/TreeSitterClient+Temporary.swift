//
//  TreeSitterClient+Temporary.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/24/25.
//

import AppKit
import SwiftTreeSitter
import CodeEditLanguages

extension TreeSitterClient {
    static func quickHighlight(
        string: String,
        theme: EditorTheme,
        font: NSFont,
        language: CodeLanguage
    ) -> NSAttributedString? {
        guard let parserLanguage = language.language, let query = TreeSitterModel.shared.query(for: language.id) else {
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
            let highlights: [HighlightRange] = queryCursor
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
        } catch {
            return nil
        }
    }
}
