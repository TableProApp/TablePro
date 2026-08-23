//
//  LineFoldRibbonView+Draw.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/8/25.
//

import AppKit
import CodeEditTextView

extension LineFoldRibbonView {
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let model,
              let layoutManager = model.controller?.textView.layoutManager,
              let range = documentRange(covering: dirtyRect, layoutManager: layoutManager) else {
            return
        }

        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: dirtyRect)

        if let hovered = model.hoveredFold, !model.isCollapsed(hovered) {
            drawExtent(of: hovered, in: context, using: layoutManager)
        }

        let foldsByLine = foldsByStartLine(in: range, layoutManager: layoutManager)

        for (lineNumber, fold) in foldsByLine {
            guard let line = layoutManager.textLineForIndex(lineNumber) else { continue }
            drawChevron(for: fold, on: line, model: model)
        }
    }

    /// Draws the disclosure chevron for one fold, centred on the line that opens it.
    ///
    /// An open fold only has a chevron while the pointer is over the gutter. A collapsed one always does, since it is
    /// the only sign left that anything is hidden there.
    private func drawChevron(
        for fold: FoldRange,
        on line: TextLineStorage<TextLine>.TextLinePosition,
        model: LineFoldModel
    ) {
        let isCollapsed = model.isCollapsed(fold)
        let isHovered = model.hoveredFold?.id == fold.id
        guard isCollapsed || isPointerInGutter else { return }

        let color = if isHovered {
            hoveredChevronColor
        } else if isCollapsed {
            collapsedChevronColor
        } else {
            chevronColor
        }

        guard let image = chevron(isCollapsed: isCollapsed, color: color) else { return }

        image.draw(
            in: CGRect(
                x: ((bounds.width - image.size.width) / 2).rounded(),
                y: (line.yPos + ((line.height - image.size.height) / 2)).rounded(),
                width: image.size.width,
                height: image.size.height
            )
        )
    }

    /// Draws how far the hovered fold reaches, from the line it opens on to the line it closes on.
    ///
    /// A chevron on its own says a block can be folded but not how much of the document that is. The bar answers
    /// that for the one fold the pointer is on, and is gone the moment the pointer is.
    private func drawExtent(
        of fold: FoldRange,
        in context: CGContext,
        using layoutManager: TextLayoutManager
    ) {
        guard let startLine = layoutManager.textLineForOffset(fold.range.lowerBound),
              let endLine = layoutManager.textLineForOffset(max(fold.range.lowerBound, fold.range.upperBound - 1))
        else {
            return
        }

        let top = startLine.yPos + startLine.height
        let bottom = endLine.yPos + endLine.height
        guard bottom > top else { return }

        let rect = CGRect(
            x: ((bounds.width - Self.extentWidth) / 2).rounded(),
            y: top,
            width: Self.extentWidth,
            height: bottom - top
        )

        context.setFillColor(foldExtentColor.cgColor)
        context.addPath(
            CGPath(
                roundedRect: rect,
                cornerWidth: Self.extentWidth / 2,
                cornerHeight: Self.extentWidth / 2,
                transform: nil
            )
        )
        context.fillPath()
    }
}
