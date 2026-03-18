//
//  LineFoldRibbonView+Draw.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/8/25.
//

import AppKit
import CodeEditTextView

extension LineFoldRibbonView {
    struct DrawingFoldInfo {
        let fold: FoldRange
        let startLine: TextLineStorage<TextLine>.TextLinePosition
        let endLine: TextLineStorage<TextLine>.TextLinePosition
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let layoutManager = model?.controller?.textView.layoutManager,
              // Find the visible lines in the rect AppKit is asking us to draw.
              let rangeStart = layoutManager.textLineForPosition(dirtyRect.minY),
              let rangeEnd = layoutManager.textLineForPosition(dirtyRect.maxY) else {
            return
        }

        context.saveGState()
        context.clip(to: dirtyRect)

        // Only draw folds in the requested dirty rect
        let folds = getDrawingFolds(
            forTextRange: rangeStart.range.location..<rangeEnd.range.upperBound,
            layoutManager: layoutManager
        )
        let foldCaps = FoldCapInfo(folds)

        // Draw non-collapsed folds first
        for fold in folds.filter({ !$0.fold.isCollapsed }) {
            drawFoldMarker(
                fold,
                foldCaps: foldCaps,
                in: context,
                using: layoutManager
            )
        }

        // Collapsed folds should *always* be on top of non-collapsed, so we draw them last.
        for fold in folds.filter({ $0.fold.isCollapsed }) {
            drawFoldMarker(
                fold,
                foldCaps: foldCaps,
                in: context,
                using: layoutManager
            )
        }

        context.restoreGState()
    }

    // MARK: - Get Drawing Folds

    /// Generates drawable fold info for a range of text.
    ///
    /// The fold storage intentionally does not store the full ranges of all folds at each interval. We may, for an
    /// interval, find that we only receive fold information for depths > 1. In this case, we still need to draw those
    /// layers of color to create the illusion that those folds are continuous under the nested folds. To achieve this,
    /// we create 'fake' folds that span more than the queried text range. When returned for drawing, the drawing
    /// methods will draw those extra folds normally.
    ///
    /// - Parameters:
    ///   - textRange: The range of characters in text to create drawing fold info for.
    ///   - layoutManager: A layout manager to query for line layout information.
    /// - Returns: A list of folds to draw for the given text range.
    private func getDrawingFolds(
        forTextRange textRange: Range<Int>,
        layoutManager: TextLayoutManager
    ) -> [DrawingFoldInfo] {
        var folds = model?.getFolds(in: textRange) ?? []

        // Add in some fake depths, we can draw these underneath the rest of the folds to make it look like it's
        // continuous
        if let minimumDepth = folds.min(by: { $0.depth < $1.depth })?.depth {
            for depth in (1..<minimumDepth).reversed() {
                folds.insert(
                    FoldRange(
                        id: .max,
                        depth: depth,
                        range: (textRange.lowerBound)..<(textRange.upperBound + 1),
                        isCollapsed: false
                    ),
                    at: 0
                )
            }
        }

        return folds.compactMap { fold in
            guard let startLine = layoutManager.textLineForOffset(fold.range.lowerBound),
                  let endLine = layoutManager.textLineForOffset(fold.range.upperBound) else {
                return nil
            }

            return DrawingFoldInfo(fold: fold, startLine: startLine, endLine: endLine)
        }
    }

    // MARK: - Draw Fold Marker

    /// Draw a single fold marker for a fold.
    ///
    /// Ensure the correct fill color is set on the drawing context before calling.
    ///
    /// - Parameters:
    ///   - foldInfo: The fold to draw.
    ///   - foldCaps:
    ///   - context: The drawing context to use.
    ///   - layoutManager: A layout manager used to retrieve position information for lines.
    private func drawFoldMarker(
        _ foldInfo: DrawingFoldInfo,
        foldCaps: FoldCapInfo,
        in context: CGContext,
        using layoutManager: TextLayoutManager
    ) {
        let minYPosition = foldInfo.startLine.yPos
        let maxYPosition = foldInfo.endLine.yPos + foldInfo.endLine.height
        let foldRect = NSRect(x: 0, y: minYPosition + 1, width: 7, height: maxYPosition - minYPosition - 2)

        if foldInfo.fold.isCollapsed {
            drawCollapsedFold(
                foldInfo: foldInfo,
                minYPosition: minYPosition,
                maxYPosition: maxYPosition,
                in: context
            )
        } else if hoveringFold.fold?.isHoveringEqual(foldInfo.fold) == true {
            drawHoveredFold(
                foldInfo: foldInfo,
                foldCaps: foldCaps,
                foldRect: foldRect,
                in: context
            )
        } else {
            drawNestedFold(
                foldInfo: foldInfo,
                foldCaps: foldCaps,
                foldRect: foldCaps.adjustFoldRect(using: foldInfo, rect: foldRect),
                in: context
            )
        }
    }

    // MARK: - Collapsed Fold

    private func drawCollapsedFold(
        foldInfo: DrawingFoldInfo,
        minYPosition: CGFloat,
        maxYPosition: CGFloat,
        in context: CGContext
    ) {
        context.saveGState()

        let fillRect = CGRect(x: 0, y: minYPosition + 1.0, width: Self.width, height: maxYPosition - minYPosition - 2.0)

        let height = 5.0
        let minX = 2.0
        let maxX = Self.width - 2.0
        let centerY = minYPosition + (maxYPosition - minYPosition)/2
        let minY = centerY - (height/2)
        let maxY = centerY + (height/2)
        let chevron = CGMutablePath()

        chevron.move(to: CGPoint(x: minX, y: minY))
        chevron.addLine(to: CGPoint(x: maxX, y: centerY))
        chevron.addLine(to: CGPoint(x: minX, y: maxY))

        if let hoveringFoldMask = hoveringFold.foldMask,
           hoveringFoldMask.intersects(CGPath(rect: fillRect, transform: .none)) {
            context.addPath(hoveringFoldMask)
            context.clip()
        }

        context.setStrokeColor(foldedIndicatorChevronColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(1.3)

        context.setFillColor(foldedIndicatorColor)
        context.fill(fillRect)
        context.addPath(chevron)
        context.strokePath()

        context.restoreGState()
    }

    // MARK: - Hovered Fold

    private func drawHoveredFold(
        foldInfo: DrawingFoldInfo,
        foldCaps: FoldCapInfo,
        foldRect: NSRect,
        in context: CGContext
    ) {
        context.saveGState()
        let plainRect = foldRect.transform(x: -2.0, y: -1.0, width: 4.0, height: 2.0)
        let roundedRect = NSBezierPath(
            roundedRect: plainRect,
            xRadius: plainRect.width / 2,
            yRadius: plainRect.width / 2
        )

        context.setFillColor(hoverFillColor.copy(alpha: hoveringFold.progress) ?? hoverFillColor)
        context.setStrokeColor(hoverBorderColor.copy(alpha: hoveringFold.progress) ?? hoverBorderColor)
        context.addPath(roundedRect.cgPathFallback)
        context.drawPath(using: .fillStroke)

        // Add the little arrows if we're not hovering right on a collapsed guy
        if foldCaps.hoveredFoldShouldDrawTopChevron(foldInfo) {
            drawChevron(in: context, yPosition: plainRect.minY + 8, pointingUp: false)
        }
        if foldCaps.hoveredFoldShouldDrawBottomChevron(foldInfo) {
            drawChevron(in: context, yPosition: plainRect.maxY - 8, pointingUp: true)
        }

        let plainMaskRect = foldRect.transform(y: 1.0, height: -2.0)
        let roundedMaskRect = NSBezierPath(roundedRect: plainMaskRect, xRadius: Self.width / 2, yRadius: Self.width / 2)
        hoveringFold.foldMask = roundedMaskRect.cgPathFallback

        context.restoreGState()
    }

    private func drawChevron(in context: CGContext, yPosition: CGFloat, pointingUp: Bool) {
        context.saveGState()
        let path = CGMutablePath()
        let chevronSize = CGSize(width: 4.0, height: 2.5)

        let center = (Self.width / 2)
        let minX = center - (chevronSize.width / 2)
        let maxX = center + (chevronSize.width / 2)

        let startY = if pointingUp {
            yPosition + chevronSize.height
        } else {
            yPosition - chevronSize.height
        }

        context.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(hoveringFold.progress).cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(1.3)

        path.move(to: CGPoint(x: minX, y: startY))
        path.addLine(to: CGPoint(x: center, y: yPosition))
        path.addLine(to: CGPoint(x: maxX, y: startY))

        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    // MARK: - Nested Fold

    private func drawNestedFold(
        foldInfo: DrawingFoldInfo,
        foldCaps: FoldCapInfo,
        foldRect: NSRect,
        in context: CGContext
    ) {
        context.saveGState()
        let roundedRect = NSBezierPath(
            roundingRect: foldRect,
            capTop: foldCaps.foldNeedsTopCap(foldInfo),
            capBottom: foldCaps.foldNeedsBottomCap(foldInfo),
            cornerRadius: foldRect.width / 2.0
        )

        context.setFillColor(markerColor)
        context.addPath(roundedRect.cgPathFallback)
        context.drawPath(using: .fill)

        // Add small white line if we're overlapping with other markers
        if foldInfo.fold.depth != 0 {
            drawOutline(
                foldInfo: foldInfo,
                foldCaps: foldCaps,
                foldRect: foldRect,
                originalPath: roundedRect.cgPathFallback,
                in: context
            )
        }

        context.restoreGState()
    }

    // MARK: - Nested Outline

    /// Draws a rounded outline for a rectangle, creating the small, light, outline around each fold indicator.
    ///
    /// This function does not change fill colors for the given context.
    ///
    /// - Parameters:
    ///   - minYPosition: The minimum y position of the rectangle to outline.
    ///   - maxYPosition: The maximum y position of the rectangle to outline.
    ///   - originalPath: The original bezier path for the rounded rectangle.
    ///   - context: The context to draw in.
    private func drawOutline(
        foldInfo: DrawingFoldInfo,
        foldCaps: FoldCapInfo,
        foldRect: NSRect,
        originalPath: CGPath,
        in context: CGContext
    ) {
        context.saveGState()

        let plainRect = foldRect.transform(x: -1.0, y: -1.0, width: 2.0, height: 2.0)
        let roundedRect = NSBezierPath(
            roundingRect: plainRect,
            capTop: foldCaps.foldNeedsTopCap(foldInfo),
            capBottom: foldCaps.foldNeedsBottomCap(foldInfo),
            cornerRadius: plainRect.width / 2.0
        )
        roundedRect.transform(using: .init(translationByX: -1.0, byY: 0.0))

        let combined = CGMutablePath()
        combined.addPath(roundedRect.cgPathFallback)
        combined.addPath(originalPath)

        context.clip(to: foldRect.transform(y: -1.0, height: 2.0))
        context.addPath(combined)
        context.setFillColor(markerBorderColor)
        context.drawPath(using: .eoFill)

        context.restoreGState()
    }
}
