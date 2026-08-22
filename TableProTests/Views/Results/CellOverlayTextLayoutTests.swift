//
//  CellOverlayTextLayoutTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

/// A cell holds one value, so an inline overlay behaves like a field editor and scrolls a long line
/// rather than wrapping it. Wrapping made TextKit 2 lay the whole paragraph out before the overlay
/// could appear: 206ms for a 256KB value and 816ms for 1MB, against 7ms unwrapped (#2381).
@Suite("Cell overlay text layout")
@MainActor
struct CellOverlayTextLayoutTests {
    private func makeTextView(width: CGFloat = 140) -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        CellOverlayBase.applyCellTextLayout(to: textView)
        return textView
    }

    @Test("A long line is not wrapped into the cell's width")
    func longLineIsNotWrapped() throws {
        let textView = makeTextView()
        let container = try #require(textView.textContainer)

        #expect(!container.widthTracksTextView)
        #expect(container.size.width == CGFloat.greatestFiniteMagnitude)
    }

    /// A text view grows only as far as `maxSize`, which `init(frame:)` leaves at the frame size, so
    /// leaving it alone clips the long line at the cell's width instead of scrolling it. Measured:
    /// a 64,000-character value produced a 140pt document view without this and 344,166pt with it.
    @Test("A long line makes the editor scrollable rather than clipping it")
    func longLineScrollsRatherThanClipping() throws {
        let textView = makeTextView()
        let layoutManager = try #require(textView.textLayoutManager, "the overlay has to be on TextKit 2")
        textView.string = String(repeating: "some cell value ", count: 4_000)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        textView.layout()

        #expect(textView.maxSize.width == CGFloat.greatestFiniteMagnitude)
        #expect(textView.frame.width > 1_000, "the document has to outgrow the cell for scrolling to reach the text")
    }

    @Test("A short value still lays out inside the cell")
    func shortValueStillLaysOut() throws {
        let textView = makeTextView()
        let layoutManager = try #require(textView.textLayoutManager)
        textView.string = "42"
        layoutManager.ensureLayout(for: layoutManager.documentRange)

        #expect(textView.string == "42")
    }

    /// The viewer shares the editor's layout, so a read-only table cannot reach the same freeze by
    /// opening a huge value inline.
    @Test("The overlay layout is one definition, shared by editor and viewer")
    func editorAndViewerShareTheLayout() throws {
        let editorTextView = makeTextView()
        let viewerTextView = makeTextView(width: 300)

        #expect(editorTextView.textContainer?.widthTracksTextView == false)
        #expect(viewerTextView.textContainer?.widthTracksTextView == false)
        #expect(editorTextView.maxSize == viewerTextView.maxSize)
    }
}
