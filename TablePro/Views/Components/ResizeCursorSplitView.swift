//
//  ResizeCursorSplitView.swift
//  TablePro
//

import AppKit

internal enum SplitDividerCursorGeometry {
    static func dividerHitRects(
        subviewFrames: [CGRect],
        collapsed: [Bool],
        isVertical: Bool,
        padding: CGFloat,
        bounds: CGRect
    ) -> [CGRect] {
        guard subviewFrames.count == collapsed.count, subviewFrames.count >= 2 else { return [] }

        var rects: [CGRect] = []
        for index in 0..<(subviewFrames.count - 1) where !collapsed[index] && !collapsed[index + 1] {
            let first = subviewFrames[index]
            let second = subviewFrames[index + 1]
            if isVertical {
                let (start, end) = gap(first.minX, first.maxX, second.minX, second.maxX)
                rects.append(
                    CGRect(
                        x: start - padding,
                        y: bounds.minY,
                        width: end - start + padding * 2,
                        height: bounds.height
                    )
                )
            } else {
                let (start, end) = gap(first.minY, first.maxY, second.minY, second.maxY)
                rects.append(
                    CGRect(
                        x: bounds.minX,
                        y: start - padding,
                        width: bounds.width,
                        height: end - start + padding * 2
                    )
                )
            }
        }
        return rects
    }

    static func isWithinDivider(point: CGPoint, hitRects: [CGRect]) -> Bool {
        hitRects.contains { $0.contains(point) }
    }

    private static func gap(
        _ firstMin: CGFloat,
        _ firstMax: CGFloat,
        _ secondMin: CGFloat,
        _ secondMax: CGFloat
    ) -> (start: CGFloat, end: CGFloat) {
        firstMax <= secondMin ? (firstMax, secondMin) : (secondMax, firstMin)
    }
}

@MainActor
internal final class ResizeCursorSplitView: NSSplitView {
    private static let hitPadding: CGFloat = 3

    private var cursorTrackingArea: NSTrackingArea?
    private var isShowingResizeCursor = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isWithinDivider(point) else {
            restoreCursorIfNeeded()
            super.mouseMoved(with: event)
            return
        }
        resizeCursor.set()
        isShowingResizeCursor = true
    }

    override func mouseExited(with event: NSEvent) {
        restoreCursorIfNeeded()
        super.mouseExited(with: event)
    }

    private func restoreCursorIfNeeded() {
        guard isShowingResizeCursor else { return }
        NSCursor.arrow.set()
        isShowingResizeCursor = false
    }

    private func isWithinDivider(_ point: CGPoint) -> Bool {
        let hitRects = SplitDividerCursorGeometry.dividerHitRects(
            subviewFrames: subviews.map(\.frame),
            collapsed: subviews.map { isSubviewCollapsed($0) },
            isVertical: isVertical,
            padding: Self.hitPadding,
            bounds: bounds
        )
        return SplitDividerCursorGeometry.isWithinDivider(point: point, hitRects: hitRects)
    }

    private var resizeCursor: NSCursor {
        if #available(macOS 15.0, *) {
            return isVertical
                ? .columnResize(directions: [.left, .right])
                : .rowResize(directions: [.up, .down])
        }
        return isVertical ? .resizeLeftRight : .resizeUpDown
    }
}

@MainActor
internal class ResizeCursorSplitViewController: NSSplitViewController {
    override func loadView() {
        let cursorSplitView = ResizeCursorSplitView()
        splitView = cursorSplitView
        view = cursorSplitView
    }
}
