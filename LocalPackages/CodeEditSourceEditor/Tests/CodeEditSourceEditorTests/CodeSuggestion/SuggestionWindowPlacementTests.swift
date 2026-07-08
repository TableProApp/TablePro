import AppKit
@testable import CodeEditSourceEditor
import XCTest

final class SuggestionWindowPlacementTests: XCTestCase {
    private let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let editorFrame = NSRect(x: 100, y: 150, width: 900, height: 600)
    private let font = NSFont.systemFont(ofSize: 12)

    func test_compute_clampsCursorNearRightEdgeWithinEditorMaxX() {
        let cursorRect = NSRect(x: 980, y: 500, width: 6, height: 16)
        let windowSize = NSSize(width: 280, height: 200)

        let placement = SuggestionWindowPlacement.compute(
            windowSize: windowSize, cursorRect: cursorRect, font: font,
            screenFrame: screenFrame, editorFrame: editorFrame
        )

        XCTAssertGreaterThanOrEqual(placement.origin.x, editorFrame.minX)
        XCTAssertLessThanOrEqual(placement.origin.x + windowSize.width, editorFrame.maxX)
    }

    func test_compute_widthGrowthAcrossResizesStaysWithinEditorMaxX() {
        let cursorRect = NSRect(x: 900, y: 500, width: 6, height: 16)

        let narrow = SuggestionWindowPlacement.compute(
            windowSize: NSSize(width: 100, height: 200), cursorRect: cursorRect, font: font,
            screenFrame: screenFrame, editorFrame: editorFrame
        )
        let grown = SuggestionWindowPlacement.compute(
            windowSize: NSSize(width: 280, height: 200), cursorRect: cursorRect, font: font,
            screenFrame: screenFrame, editorFrame: editorFrame
        )

        XCTAssertLessThanOrEqual(narrow.origin.x + 100, editorFrame.maxX)
        XCTAssertLessThanOrEqual(grown.origin.x + 280, editorFrame.maxX)
    }

    func test_compute_leftAlignsWhenWiderThanEditor() {
        let narrowEditorFrame = NSRect(x: 100, y: 150, width: 200, height: 600)
        let cursorRect = NSRect(x: 200, y: 500, width: 6, height: 16)
        let windowSize = NSSize(width: 280, height: 200)

        let placement = SuggestionWindowPlacement.compute(
            windowSize: windowSize, cursorRect: cursorRect, font: font,
            screenFrame: screenFrame, editorFrame: narrowEditorFrame
        )

        XCTAssertEqual(placement.origin.x, narrowEditorFrame.minX + SuggestionWindowPlacement.edgePadding)
    }

    func test_compute_flipsAboveCursorWhenBelowSpaceIsInsufficient() {
        let cursorRect = NSRect(x: 300, y: 200, width: 6, height: 16)

        let placement = SuggestionWindowPlacement.compute(
            windowSize: NSSize(width: 280, height: 100), cursorRect: cursorRect, font: font,
            screenFrame: screenFrame, editorFrame: editorFrame
        )

        XCTAssertTrue(placement.isAboveCursor)
        XCTAssertGreaterThanOrEqual(placement.origin.y, editorFrame.minY)
    }

    func test_compute_growingHeightAcrossResizesStaysWithinEditorMaxY() {
        let cursorRect = NSRect(x: 300, y: 200, width: 6, height: 16)

        let mid = SuggestionWindowPlacement.compute(
            windowSize: NSSize(width: 280, height: 400), cursorRect: cursorRect, font: font,
            screenFrame: screenFrame, editorFrame: editorFrame
        )
        let grown = SuggestionWindowPlacement.compute(
            windowSize: NSSize(width: 280, height: 560), cursorRect: cursorRect, font: font,
            screenFrame: screenFrame, editorFrame: editorFrame
        )

        XCTAssertTrue(mid.isAboveCursor)
        XCTAssertTrue(grown.isAboveCursor)
        XCTAssertLessThanOrEqual(mid.origin.y + 400, editorFrame.maxY)
        XCTAssertEqual(grown.origin.y + 560, editorFrame.maxY, accuracy: 0.001)
    }

    func test_compute_fallsBackToScreenFrameWhenEditorFrameIsNil() {
        let cursorRect = NSRect(x: 1300, y: 500, width: 6, height: 16)
        let windowSize = NSSize(width: 280, height: 200)

        let placement = SuggestionWindowPlacement.compute(
            windowSize: windowSize, cursorRect: cursorRect, font: font,
            screenFrame: screenFrame, editorFrame: nil
        )

        XCTAssertLessThanOrEqual(placement.origin.x + windowSize.width, screenFrame.maxX)
    }
}
