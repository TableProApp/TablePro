//
//  SuggestionWindowPlacement.swift
//  CodeEditSourceEditor
//

import AppKit

/// The fixed anchor for a completion session: where the caret is, the editor font,
/// and the editor's screen frame. Retained by ``SuggestionController`` so placement can be
/// re-derived on every resize instead of patched from the panel's previous frame.
internal struct SuggestionPlacementAnchor {
    let cursorRect: NSRect
    let font: NSFont
    let editorFrame: NSRect?
}

/// Pure placement math for the suggestion panel. Operates on plain rects so it is unit testable
/// without an `NSWindow`, and is re-invoked on every resize so the panel is re-derived from the
/// same caret anchor rather than drifting from its last frame as its content grows.
internal enum SuggestionWindowPlacement {
    internal static let edgePadding: CGFloat = 22

    internal struct Placement: Equatable {
        let origin: NSPoint
        let isAboveCursor: Bool
    }

    internal static func compute(
        windowSize: NSSize,
        cursorRect: NSRect,
        font: NSFont,
        screenFrame: NSRect,
        editorFrame: NSRect?
    ) -> Placement {
        let x = clampedX(
            windowSize: windowSize,
            cursorRect: cursorRect,
            font: font,
            screenFrame: screenFrame,
            editorFrame: editorFrame
        )
        let (y, isAboveCursor) = clampedY(
            windowSize: windowSize,
            cursorRect: cursorRect,
            screenFrame: screenFrame
        )
        return Placement(origin: NSPoint(x: x, y: y), isAboveCursor: isAboveCursor)
    }

    private static func clampedX(
        windowSize: NSSize,
        cursorRect: NSRect,
        font: NSFont,
        screenFrame: NSRect,
        editorFrame: NSRect?
    ) -> CGFloat {
        let anchorX = cursorRect.origin.x - SuggestionController.WINDOW_PADDING
            - CodeSuggestionLabelView.HORIZONTAL_PADDING - font.pointSize

        let leftLimit = max(screenFrame.minX, editorFrame?.minX ?? screenFrame.minX)
        let rightLimit = min(screenFrame.maxX, editorFrame?.maxX ?? screenFrame.maxX)

        let minX = leftLimit + edgePadding
        let maxX = rightLimit - windowSize.width - edgePadding

        guard maxX >= minX else { return minX }
        if anchorX < minX { return minX }
        if anchorX > maxX { return maxX }
        return anchorX
    }

    /// Minimum room below the caret before the panel flips above it, in screen points.
    internal static let minRoomBelowCaret: CGFloat = 90

    /// The panel is always anchored to the caret: dropping below it (top edge at the caret's baseline) so the current
    /// line stays visible, or flipping above it (bottom edge at the caret's top) only when there is little room below
    /// on the screen and more above. The panel is never pinned to a screen edge, so it stays next to the caret and may
    /// overflow the editor into the results area; a tall panel simply clips at the screen edge it runs into. Clicks
    /// over the overflow dismiss it.
    private static func clampedY(
        windowSize: NSSize,
        cursorRect: NSRect,
        screenFrame: NSRect
    ) -> (y: CGFloat, isAboveCursor: Bool) {
        let spaceBelow = cursorRect.origin.y - screenFrame.minY
        let spaceAbove = screenFrame.maxY - (cursorRect.origin.y + cursorRect.height)

        if spaceBelow >= minRoomBelowCaret || spaceBelow >= spaceAbove {
            return (cursorRect.origin.y - windowSize.height, false)
        }
        return (cursorRect.origin.y + cursorRect.height, true)
    }
}
