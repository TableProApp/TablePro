//
//  FoldPlaceholderSummary.swift
//  CodeEditSourceEditor
//

import Foundation

/// Describes the content hidden by a collapsed fold, so a placeholder can preview it.
public struct FoldPlaceholderSummary: Equatable, Sendable {
    /// The number of UTF-16 units read from the folded region to build the preview.
    public static let scanWindow = 200

    /// The longest preview string produced, before any provider adds a line count to it.
    public static let maxPreviewLength = 40

    public let previewText: String
    public let hiddenLineCount: Int

    public init(previewText: String, hiddenLineCount: Int) {
        self.previewText = previewText
        self.hiddenLineCount = hiddenLineCount
    }

    /// Builds a summary for a folded region.
    ///
    /// Only ``scanWindow`` units are read, so a fold hiding a multi-megabyte line costs the same as one hiding a short
    /// one.
    public static func summarize(content: NSString, foldRange: Range<Int>, hiddenLineCount: Int) -> Self {
        let start = max(0, min(foldRange.lowerBound, content.length))
        let end = max(start, min(foldRange.upperBound, content.length))
        let windowLength = min(end - start, scanWindow)
        guard windowLength > 0 else {
            return Self(previewText: "", hiddenLineCount: max(0, hiddenLineCount))
        }

        let window = content.substring(with: NSRange(location: start, length: windowLength))
        let collapsed = window
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return Self(
            previewText: truncate(collapsed, to: maxPreviewLength),
            hiddenLineCount: max(0, hiddenLineCount)
        )
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        var count = 0
        var endIndex = text.startIndex
        for index in text.indices {
            if count == limit {
                return String(text[text.startIndex..<endIndex]) + "\u{2026}"
            }
            count += 1
            endIndex = text.index(after: index)
        }
        return text
    }
}
