//
//  FoldPreviewMetrics.swift
//  TablePro
//

import AppKit

/// What a fold peek shows and how large it has to be.
///
/// Kept free of any view so the popover's size can be checked without a window. A popover sized to zero never
/// appears at all, and that failure is invisible to a UI test, so the arithmetic is pinned by unit tests instead.
enum FoldPreviewMetrics {
    /// The most lines a peek shows before it reports the rest as a count.
    static let maxLines = 24

    /// The widest a peek grows before its longest line scrolls, in points.
    static let maxWidth: CGFloat = 620

    /// The narrowest a peek gets, so a one-word block still reads as a panel.
    static let minWidth: CGFloat = 240

    /// Room for the editor's content insets, in points.
    private static let verticalPadding: CGFloat = 16
    private static let horizontalPadding: CGFloat = 24

    struct Layout: Equatable {
        /// The lines the peek shows, without a trailing newline.
        let text: String
        /// How many lines of the block the peek left out.
        let hiddenLineCount: Int
        /// The size the popover's content needs.
        let size: CGSize
    }

    /// Lays out a peek for a block of code.
    ///
    /// Indentation is left exactly as the document has it. A peek that re-indents its content stops matching the
    /// code the reader is looking at, which is the one thing a peek has to do.
    static func layout(for block: String, font: NSFont) -> Layout {
        let lines = significantLines(of: block)
        let shown = Array(lines.prefix(maxLines))
        let hiddenLineCount = lines.count - shown.count

        let lineHeight = CodeBlockHeightEstimator.editorLineHeight(for: font)
        let widest = shown.reduce(CGFloat.zero) { widest, line in
            max(widest, (line as NSString).size(withAttributes: [.font: font]).width)
        }

        return Layout(
            text: shown.joined(separator: "\n"),
            hiddenLineCount: hiddenLineCount,
            size: CGSize(
                width: min(max(ceil(widest) + horizontalPadding, minWidth), maxWidth),
                height: ceil(CGFloat(max(shown.count, 1)) * lineHeight) + verticalPadding
            )
        )
    }

    /// The block's lines with blank ones at either end dropped.
    ///
    /// A fold's last line is the one holding its closing token, and reading to the end of that line carries the
    /// newline after it, which would otherwise show as an empty final row.
    private static func significantLines(of block: String) -> [String] {
        var lines = block.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines
    }
}
