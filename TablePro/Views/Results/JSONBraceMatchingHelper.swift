//
//  JSONBraceMatchingHelper.swift
//  TablePro
//
//  Highlights matching {}/[] braces when the cursor is adjacent to one.
//

import AppKit

final class JSONBraceMatchingHelper {
    private weak var textView: NSTextView?
    private var lastHighlightedRanges: [NSRange] = []
    private static let highlightColor = NSColor.systemYellow.withAlphaComponent(0.3)
    private static let maxScanLength = 10_000

    init(textView: NSTextView) {
        self.textView = textView
    }

    func updateBraceHighlight() {
        clearHighlights()

        guard let textView else { return }
        guard let layoutManager = textView.layoutManager else { return }

        let text = textView.string as NSString
        let length = text.length
        guard length > 0 else { return }

        let cursor = textView.selectedRange().location
        guard cursor != NSNotFound else { return }

        var bracePosition: Int?

        if let pos = braceAt(position: cursor, in: text) {
            bracePosition = pos
        } else if cursor > 0, let pos = braceAt(position: cursor - 1, in: text) {
            bracePosition = pos
        }

        guard let position = bracePosition else { return }
        guard let matchPosition = findMatchingBrace(from: position, in: text) else { return }

        let ranges = [
            NSRange(location: position, length: 1),
            NSRange(location: matchPosition, length: 1)
        ]

        for range in ranges {
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: Self.highlightColor,
                forCharacterRange: range
            )
        }

        lastHighlightedRanges = ranges
    }

    private func clearHighlights() {
        guard let layoutManager = textView?.layoutManager else { return }
        for range in lastHighlightedRanges {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        lastHighlightedRanges = []
    }

    private func findMatchingBrace(from position: Int, in text: NSString) -> Int? {
        let length = text.length
        guard position >= 0, position < length else { return nil }

        let char = text.character(at: position)
        let openBrace: unichar
        let closeBrace: unichar
        let forward: Bool

        switch char {
        case leftCurly:
            openBrace = leftCurly; closeBrace = rightCurly; forward = true
        case leftSquare:
            openBrace = leftSquare; closeBrace = rightSquare; forward = true
        case rightCurly:
            openBrace = leftCurly; closeBrace = rightCurly; forward = false
        case rightSquare:
            openBrace = leftSquare; closeBrace = rightSquare; forward = false
        default:
            return nil
        }

        var depth = 1
        var inString = false
        let maxScan = Self.maxScanLength

        if forward {
            var i = position + 1
            var scanned = 0
            while i < length, scanned < maxScan {
                let ch = text.character(at: i)

                if ch == quote, !isEscaped(at: i, in: text) {
                    inString.toggle()
                } else if !inString {
                    if ch == openBrace {
                        depth += 1
                    } else if ch == closeBrace {
                        depth -= 1
                        if depth == 0 { return i }
                    }
                }

                i += 1
                scanned += 1
            }
        // Backward scan: first determine string-state at each position via forward pass,
        // then walk backward using the precomputed state.
        } else {
            // Build in-string map from start to target position via forward scan
            var stringState = [Bool](repeating: false, count: min(position + 1, length))
            var fwdInString = false
            for j in 0..<stringState.count {
                let ch = text.character(at: j)
                if ch == quote, !isEscaped(at: j, in: text) {
                    fwdInString.toggle()
                }
                stringState[j] = fwdInString
            }

            var i = position - 1
            var scanned = 0
            while i >= 0, scanned < maxScan {
                if !stringState[i] {
                    let ch = text.character(at: i)
                    if ch == closeBrace {
                        depth += 1
                    } else if ch == openBrace {
                        depth -= 1
                        if depth == 0 { return i }
                    }
                }
                i -= 1
                scanned += 1
            }
        }

        return nil
    }

    private func braceAt(position: Int, in text: NSString) -> Int? {
        guard position >= 0, position < text.length else { return nil }
        let ch = text.character(at: position)
        if ch == leftCurly || ch == rightCurly || ch == leftSquare || ch == rightSquare {
            return position
        }
        return nil
    }

    // Checks if the quote at `position` is preceded by an odd number of backslashes
    private func isEscaped(at position: Int, in text: NSString) -> Bool {
        var backslashCount = 0
        var i = position - 1
        while i >= 0, text.character(at: i) == backslash {
            backslashCount += 1
            i -= 1
        }
        return backslashCount % 2 != 0
    }
}

// MARK: - Character Constants

private extension JSONBraceMatchingHelper {
    var leftCurly: unichar { 0x7B }    // {
    var rightCurly: unichar { 0x7D }   // }
    var leftSquare: unichar { 0x5B }   // [
    var rightSquare: unichar { 0x5D }  // ]
    var quote: unichar { 0x22 }        // "
    var backslash: unichar { 0x5C }    // \
}
