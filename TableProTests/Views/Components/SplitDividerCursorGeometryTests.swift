import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("Split divider cursor geometry")
@MainActor
struct SplitDividerCursorGeometryTests {
    @Test("A vertical split places one padded, full-height rect over the divider")
    func verticalSplitProducesOneRect() {
        let rects = SplitDividerCursorGeometry.dividerHitRects(
            subviewFrames: [
                CGRect(x: 0, y: 0, width: 150, height: 200),
                CGRect(x: 151, y: 0, width: 149, height: 200)
            ],
            collapsed: [false, false],
            isVertical: true,
            padding: 3,
            bounds: CGRect(x: 0, y: 0, width: 300, height: 200)
        )
        #expect(rects == [CGRect(x: 147, y: 0, width: 7, height: 200)])
    }

    @Test("A horizontal split places one padded, full-width rect over the divider")
    func horizontalSplitProducesOneRect() {
        let rects = SplitDividerCursorGeometry.dividerHitRects(
            subviewFrames: [
                CGRect(x: 0, y: 0, width: 200, height: 150),
                CGRect(x: 0, y: 151, width: 200, height: 149)
            ],
            collapsed: [false, false],
            isVertical: false,
            padding: 3,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 300)
        )
        #expect(rects == [CGRect(x: 0, y: 147, width: 200, height: 7)])
    }

    @Test("Three panes produce two dividers")
    func threePanesProduceTwoDividers() {
        let rects = SplitDividerCursorGeometry.dividerHitRects(
            subviewFrames: [
                CGRect(x: 0, y: 0, width: 150, height: 200),
                CGRect(x: 151, y: 0, width: 150, height: 200),
                CGRect(x: 302, y: 0, width: 159, height: 200)
            ],
            collapsed: [false, false, false],
            isVertical: true,
            padding: 3,
            bounds: CGRect(x: 0, y: 0, width: 461, height: 200)
        )
        #expect(rects == [
            CGRect(x: 147, y: 0, width: 7, height: 200),
            CGRect(x: 298, y: 0, width: 7, height: 200)
        ])
    }

    @Test("A collapsed pane drops the divider next to it")
    func collapsedPaneDropsAdjacentDivider() {
        let rects = SplitDividerCursorGeometry.dividerHitRects(
            subviewFrames: [
                CGRect(x: 0, y: 0, width: 150, height: 200),
                CGRect(x: 151, y: 0, width: 150, height: 200),
                CGRect(x: 302, y: 0, width: 159, height: 200)
            ],
            collapsed: [false, false, true],
            isVertical: true,
            padding: 3,
            bounds: CGRect(x: 0, y: 0, width: 461, height: 200)
        )
        #expect(rects == [CGRect(x: 147, y: 0, width: 7, height: 200)])
    }

    @Test("Fewer than two panes produce no dividers")
    func singlePaneProducesNoDividers() {
        let rects = SplitDividerCursorGeometry.dividerHitRects(
            subviewFrames: [CGRect(x: 0, y: 0, width: 300, height: 200)],
            collapsed: [false],
            isVertical: true,
            padding: 3,
            bounds: CGRect(x: 0, y: 0, width: 300, height: 200)
        )
        #expect(rects.isEmpty)
    }

    @Test("A point inside the divider is detected, one outside is not")
    func hitTestingMatchesTheDividerRect() {
        let hitRects = [CGRect(x: 147, y: 0, width: 7, height: 200)]
        #expect(SplitDividerCursorGeometry.isWithinDivider(point: CGPoint(x: 150, y: 100), hitRects: hitRects))
        #expect(!SplitDividerCursorGeometry.isWithinDivider(point: CGPoint(x: 100, y: 100), hitRects: hitRects))
        #expect(!SplitDividerCursorGeometry.isWithinDivider(point: CGPoint(x: 200, y: 100), hitRects: hitRects))
    }
}
