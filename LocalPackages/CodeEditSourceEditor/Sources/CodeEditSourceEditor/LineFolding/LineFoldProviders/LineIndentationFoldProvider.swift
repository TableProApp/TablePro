//
//  LineIndentationFoldProvider.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/8/25.
//

import AppKit
import CodeEditTextView

/// A basic fold provider that uses line indentation to determine fold regions.
final class LineIndentationFoldProvider: LineFoldProvider {
    func indentLevelAtLine(substring: NSString) -> Int? {
        for idx in 0..<substring.length {
            let character = UnicodeScalar(substring.character(at: idx))
            if character?.properties.isWhitespace == false {
                return idx
            }
        }
        return nil
    }

    func foldLevelAtLine(
        lineNumber: Int,
        lineRange: NSRange,
        previousDepth: Int,
        controller: TextViewController
    ) -> [LineFoldProviderLineInfo] {
        let text = controller.textView.textStorage.string as NSString
        guard let leadingIndent = text.leadingRange(in: lineRange, within: .whitespacesAndNewlines)?.length,
              leadingIndent != lineRange.length else {
            return []
        }
        var foldIndicators: [LineFoldProviderLineInfo] = []

        let leadingDepth = leadingIndent / controller.indentOption.charCount
        if leadingDepth < previousDepth {
            // End the fold at the start of whitespace
            foldIndicators.append(
                .endFold(
                    rangeEnd: lineRange.location + leadingIndent,
                    newDepth: leadingDepth
                )
            )
        }

        // Check if the next line has more indent
        let maxRange = NSRange(start: lineRange.max, end: text.length)
        guard let nextIndent = text.leadingRange(in: maxRange, within: .whitespacesWithoutNewlines)?.length,
              nextIndent > 0 else {
            return foldIndicators
        }

        if nextIndent > leadingIndent, let trailingWhitespace = text.trailingWhitespaceRange(in: lineRange) {
            foldIndicators.append(
                .startFold(
                    rangeStart: trailingWhitespace.location,
                    newDepth: nextIndent / controller.indentOption.charCount
                )
            )
        }

        return foldIndicators
    }
}
