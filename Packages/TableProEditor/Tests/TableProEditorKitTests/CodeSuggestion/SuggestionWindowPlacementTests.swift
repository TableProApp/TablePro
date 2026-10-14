import AppKit
@testable import TableProEditorKit
import Testing

@MainActor
struct SuggestionWindowPlacementTests {
    private let screenFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
    private let editorFrame = NSRect(x: 100, y: 150, width: 900, height: 600)
    private let font = NSFont.systemFont(ofSize: 12)

    @Test func test_compute_clampsCursorNearRightEdgeWithinEditorMaxX() {
        let cursorRect = NSRect(x: 980, y: 500, width: 6, height: 16)
        let windowSize = NSSize(width: 280, height: 200)

        let placement = SuggestionWindowPlacement.compute(
            windowSize: windowSize, cursorRect: cursorRect, font: font,
            screenFrame: screenFrame, editorFrame: editorFrame
        )

        #expect(placement.origin.x >= editorFrame.minX)
        #expect(placement.origin.x + windowSize.width <= editorFrame.maxX)
    }

    @Test func test_compute_widthGrowthAcrossResizesStaysWithinEditorMaxX() {
        let cursorRect = NSRect(x: 900, y: 500, width: 6, height: 16)

        let narrow = SuggestionWindowPlacement.compute(
            windowSize: NSSize(width: 100, height: 200), cursorRect: cursorRect, font: font,
            screenFrame: screenFrame, editorFrame: editorFrame
        )
        let grown = SuggestionWindowPlacement.compute(
            windowSize: NSSize(width: 280, height: 200), cursorRect: cursorRect, font: font,
            screenFrame: screenFrame, editorFrame: editorFrame
        )

        #expect(narrow.origin.x + 100 <= editorFrame.maxX)
        #expect(grown.origin.x + 280 <= editorFrame.maxX)
    }

    @Test func test_compute_leftAlignsWhenWiderThanEditor() {
        let narrowEditorFrame = NSRect(x: 100, y: 150, width: 200, height: 600)
        let cursorRect = NSRect(x: 200, y: 500, width: 6, height: 16)
        let windowSize = NSSize(width: 280, height: 200)

        let placement = SuggestionWindowPlacement.compute(
            windowSize: windowSize, cursorRect: cursorRect, font: font,
            screenFrame: screenFrame, editorFrame: narrowEditorFrame
        )

        #expect(placement.origin.x == narrowEditorFrame.minX + SuggestionWindowPlacement.edgePadding)
    }

    @Test func test_compute_flipsAboveCursorWhenBelowScreenSpaceIsInsufficient() {
        // Caret near the screen bottom: not enough room below on the screen, so the panel flips above.
        let cursorRect = NSRect(x: 300, y: 40, width: 6, height: 16)

        let placement = SuggestionWindowPlacement.compute(
            windowSize: NSSize(width: 280, height: 200), cursorRect: cursorRect, font: font,
            screenFrame: screenFrame, editorFrame: editorFrame
        )

        #expect(placement.isAboveCursor)
        #expect(placement.origin.y >= screenFrame.minY)
    }

    @Test func test_compute_tallPanelNearEditorTopStaysBelowCaretAndOverflowsEditor() {
        // The reported bug: a tall panel with the caret near the top of a short editor must drop below the caret
        // (overflowing the editor into the results area) instead of flipping up and covering the current line.
        let shortEditor = NSRect(x: 100, y: 300, width: 900, height: 300)
        let caretNearEditorTop = NSRect(x: 300, y: 560, width: 6, height: 16)

        let placement = SuggestionWindowPlacement.compute(
            windowSize: NSSize(width: 280, height: 500), cursorRect: caretNearEditorTop, font: font,
            screenFrame: screenFrame, editorFrame: shortEditor
        )

        #expect(!placement.isAboveCursor)
        // The panel's top sits at the caret's baseline, so the current line stays visible above it.
        #expect(placement.origin.y + 500 <= caretNearEditorTop.origin.y)
        // And it is allowed to overflow the editor's bottom, constrained only by the screen.
        #expect(placement.origin.y < shortEditor.minY)
    }

    @Test func test_compute_staysAnchoredBelowCaretEvenWithMoreRoomAbove() {
        // Regression for the panel vanishing: with the caret lower on screen (more room above) but still enough
        // room below, the panel must stay anchored to the caret, not get pinned to the screen top.
        let cursorRect = NSRect(x: 300, y: 250, width: 6, height: 16)

        let placement = SuggestionWindowPlacement.compute(
            windowSize: NSSize(width: 280, height: 500), cursorRect: cursorRect, font: font,
            screenFrame: screenFrame, editorFrame: editorFrame
        )

        #expect(!placement.isAboveCursor)
        // The panel's top sits exactly at the caret's baseline, next to the caret, not up at the screen edge.
        #expect(abs((placement.origin.y + 500) - cursorRect.origin.y) <= 0.001)
    }

    @Test func test_compute_fallsBackToScreenFrameWhenEditorFrameIsNil() {
        let cursorRect = NSRect(x: 1_300, y: 500, width: 6, height: 16)
        let windowSize = NSSize(width: 280, height: 200)

        let placement = SuggestionWindowPlacement.compute(
            windowSize: windowSize, cursorRect: cursorRect, font: font,
            screenFrame: screenFrame, editorFrame: nil
        )

        #expect(placement.origin.x + windowSize.width <= screenFrame.maxX)
    }
}
