import AppKit
@testable import CodeEditTextView
import Testing

/// Regression tests for Cmd+A (`selectAll:`) when the buffer has a trailing
/// empty line (text ending in `\n`). The selection must cover the entire
/// `textStorage`, including the trailing newline — otherwise the visually
/// last line is dropped from copy/cut/replace operations.
@Suite
@MainActor
struct SelectAllWithTrailingNewlineTests {
    private func makeLaidOutTextView(_ text: String) -> TextView {
        let textView = TextView(string: text)
        textView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.updateFrameIfNeeded()
        // updateFrameIfNeeded shrinks the frame width to the longest line; force
        // back to the original width so getFillRects has horizontal room.
        textView.frame.size.width = 1_000
        textView.layoutManager.invalidateLayoutForRange(textView.documentRange)
        textView.layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1_000, height: 1_000))
        return textView
    }

    // MARK: - documentRange

    @Test("documentRange equals textStorage.length for buffer without trailing newline")
    func documentRangeNoTrailingNewline() {
        let text = "line1\nline2\nline3\nline4\nline5"
        let textView = makeLaidOutTextView(text)
        #expect(textView.documentRange == NSRange(location: 0, length: 29))
        #expect(textView.documentRange.length == (text as NSString).length)
    }

    @Test("documentRange equals textStorage.length for buffer with trailing newline")
    func documentRangeWithTrailingNewline() {
        let text = "line1\nline2\nline3\nline4\nline5\n"
        let textView = makeLaidOutTextView(text)
        #expect(textView.documentRange == NSRange(location: 0, length: 30))
        #expect(textView.documentRange.length == (text as NSString).length)
    }

    // MARK: - selectAll → selectedRange

    @Test("Cmd+A on buffer without trailing newline selects every character")
    func selectAllNoTrailingNewlineCoversAll() {
        let textView = makeLaidOutTextView("line1\nline2\nline3\nline4\nline5")
        textView.selectAll(nil)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 29))
    }

    @Test("Cmd+A on buffer with trailing newline selects every character including the newline")
    func selectAllWithTrailingNewlineCoversAll() {
        let textView = makeLaidOutTextView("line1\nline2\nline3\nline4\nline5\n")
        textView.selectAll(nil)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 30))
    }

    @Test("Cmd+A on buffer with two trailing newlines (visible blank line) selects all of it")
    func selectAllWithDoubleTrailingNewlineCoversAll() {
        let text = "line1\nline2\n\n"
        let textView = makeLaidOutTextView(text)
        textView.selectAll(nil)
        #expect(textView.selectedRange() == NSRange(location: 0, length: (text as NSString).length))
    }

    // MARK: - selectAll → copy → clipboard

    @Test("Cmd+A then native copy on trailing-newline buffer writes the full text to clipboard")
    func selectAllThenCopyWritesFullText() {
        let text = "line1\nline2\nline3\nline4\nline5\n"
        let textView = makeLaidOutTextView(text)

        // Use a fresh pasteboard so other tests don't interfere.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        textView.selectAll(nil)
        textView.copy(NSObject())

        let copied = pasteboard.string(forType: .string)
        #expect(copied == text)
    }

    /// Mirrors TablePro's `EditorEventRouter.handleKeyDown` Cmd+C intercept:
    /// after `selectAll`, take `textView.selectedRange()` + `textView.string`
    /// and substring. The substring must equal the full buffer.
    @Test("After selectAll, substring(textView.string, selectedRange) equals the full text")
    func selectAllThenManualSubstringMatchesFullText() {
        let text = "select * from products\nselect * from orders\nselect 1\n"
        let textView = makeLaidOutTextView(text)

        textView.selectAll(nil)
        let selection = textView.selectedRange()
        let copied = (textView.string as NSString).substring(with: selection)

        #expect(selection == NSRange(location: 0, length: (text as NSString).length))
        #expect(copied == text)
    }

    /// Buffer with multiple trailing newlines (visible empty lines) — checks
    /// the substring path doesn't drop the trailing content.
    @Test("After selectAll on trailing-empty-line buffer, substring includes every newline")
    func selectAllSubstringIncludesTrailingEmptyLines() {
        let text = "row1\nrow2\nrow3\nrow4\nrow5\n"
        let textView = makeLaidOutTextView(text)

        textView.selectAll(nil)
        let selection = textView.selectedRange()
        let copied = (textView.string as NSString).substring(with: selection)

        #expect(copied == text)
        #expect(copied.hasSuffix("\n"))
    }

    // MARK: - Visual highlight (fillRects)

    /// User-reported #1075: after Cmd+A on a buffer ending with `\n`, the blue
    /// highlight visually covers only the lines BEFORE the trailing empty one.
    /// `getFillRects` is what produces the highlight rectangles — it should
    /// emit one rect per visible-line fragment that the selection touches.
    @Test("getFillRects covers every text line for selectAll on trailing-newline buffer")
    func getFillRectsCoversAllLinesWithTrailingNewline() {
        let textView = makeLaidOutTextView("row1\nrow2\nrow3\nrow4\nrow5\n")
        textView.selectAll(nil)

        guard let selection = textView.selectionManager.textSelections.first else {
            Issue.record("Expected one selection")
            return
        }
        let rects = textView.selectionManager.getFillRects(
            in: textView.frame, for: selection
        )
        // Five text lines must each contribute at least one fill rect.
        #expect(rects.count >= 5, "Expected ≥5 fill rects, got \(rects.count)")
    }

    @Test("getFillRects covers every text line for selectAll on buffer without trailing newline")
    func getFillRectsCoversAllLinesWithoutTrailingNewline() {
        let textView = makeLaidOutTextView("row1\nrow2\nrow3\nrow4\nrow5")
        textView.selectAll(nil)

        guard let selection = textView.selectionManager.textSelections.first else {
            Issue.record("Expected one selection")
            return
        }
        let rects = textView.selectionManager.getFillRects(
            in: textView.frame, for: selection
        )
        #expect(rects.count >= 5, "Expected ≥5 fill rects, got \(rects.count)")
    }

    /// User-reported repro from issue #1075: SQL editor with two `select * from users;`
    /// lines plus a trailing newline. After Cmd+A, only the FIRST line shows the
    /// blue highlight; line 2's selection rect ends up zero-width because the
    /// `else` branch of `getFillRects` resolves the line-end to a 0-width rect
    /// at exactly `intersectionRange.max == lineStorage.length`.
    ///
    /// We assert against the rect's right edge instead of width — without a real
    /// window the typesetter returns zero-width glyphs in tests, so widths are
    /// always 0. The right-edge x position still differentiates the two branches:
    /// the IF branch sets `maxX` to the right edge of the fill area, while the
    /// ELSE branch leaves `maxX` near the line's leading edge (≈ `minX`).
    /// Issue #1075 — exact user repro. The buffer has two text lines plus a
    /// trailing newline. Before the fix, the LAST text line's fill rect
    /// collapsed to zero width because `intersectionRange.max ==
    /// lineStorage.length` routed it through the else branch, which resolves
    /// to the trailing-empty-line position at the leading edge.
    ///
    /// Both text lines end with `\n`, so both must extend to the right edge.
    @Test("Cmd+A on `users;\\nusers;\\n` highlights both text lines to right edge (#1075)")
    func selectAllExtendsBothLinesToRightEdge() {
        let textView = makeLaidOutTextView("select * from users;\nselect * from users;\n")
        textView.selectAll(nil)

        guard let selection = textView.selectionManager.textSelections.first else {
            Issue.record("Expected one selection")
            return
        }
        let rects = textView.selectionManager
            .getFillRects(in: textView.frame, for: selection)
            .sorted { $0.minY < $1.minY }

        guard rects.count == 2 else {
            Issue.record("Expected exactly 2 fill rects, got \(rects.count)")
            return
        }
        // Both lines must reach the available right edge (frame width here, since
        // there's no narrower wrap width).
        let frameWidth = textView.frame.width
        for (index, rect) in rects.enumerated() {
            #expect(rect.width >= frameWidth - 1.0,
                    "Line \(index) width = \(rect.width); expected ≈ \(frameWidth)")
        }
    }

    /// Counterpart: a buffer that does NOT end with `\n` should leave the
    /// last line's highlight at the text's right edge, not the frame edge —
    /// this is the original behavior we must preserve.
    @Test("Cmd+A on non-newline-terminated buffer keeps last line highlight at text end")
    func selectAllNonTerminatedKeepsLastLineAtTextEnd() {
        let textView = makeLaidOutTextView("select * from users;\nselect * from users;")
        textView.selectAll(nil)

        guard let selection = textView.selectionManager.textSelections.first else {
            Issue.record("Expected one selection")
            return
        }
        let rects = textView.selectionManager
            .getFillRects(in: textView.frame, for: selection)
            .sorted { $0.minY < $1.minY }

        guard rects.count == 2 else {
            Issue.record("Expected 2 fill rects, got \(rects.count)")
            return
        }
        // Line 1 ends with `\n` — extends to frame edge.
        let frameWidth = textView.frame.width
        #expect(rects[0].width >= frameWidth - 1.0,
                "Line 0 width = \(rects[0].width); expected ≈ \(frameWidth)")
        // Line 2 has no trailing `\n` — must NOT extend to the frame edge.
        #expect(rects[1].width < frameWidth - 1.0,
                "Line 1 width = \(rects[1].width); should not reach frame edge \(frameWidth)")
    }

    @Test("Sum of fill-rect heights covers all five visible text lines")
    func fillRectsHeightSpansAllLines() {
        let textView = makeLaidOutTextView("row1\nrow2\nrow3\nrow4\nrow5\n")
        textView.selectAll(nil)

        guard let selection = textView.selectionManager.textSelections.first,
              let firstLine = textView.layoutManager.textLineForOffset(0) else {
            Issue.record("Expected selection and a first line")
            return
        }
        let rects = textView.selectionManager.getFillRects(
            in: textView.frame, for: selection
        )
        let totalHeight = rects.map(\.height).reduce(0, +)
        // Five lines must cover ~5x a single line height. Use 4.5x as a safe lower bound.
        #expect(totalHeight >= firstLine.height * 4.5,
                "Total fill-rect height \(totalHeight) is less than 4.5x line height \(firstLine.height)")
    }
}
