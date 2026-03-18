//
//  CodeSuggestionRowView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/22/25.
//

import AppKit

/// Used to draw a custom selection highlight for the table row
final class CodeSuggestionRowView: NSTableRowView {
    var getSelectionColor: (() -> NSColor)?

    init(getSelectionColor: (() -> NSColor)? = nil) {
        self.getSelectionColor = getSelectionColor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        defer { context.restoreGState() }

        // Create a rect that's inset from the edges and has proper padding
        // TODO: We create a new selectionRect instead of using dirtyRect
        // because there is a visual bug when holding down the arrow keys
        // to select the first or last item, which draws a clipped
        // rectangular highlight shape instead of the whole rectangle.
        // Replace this when it gets fixed.
        let selectionRect = NSRect(
            x: SuggestionController.WINDOW_PADDING,
            y: 0,
            width: bounds.width - (SuggestionController.WINDOW_PADDING * 2),
            height: bounds.height
        )
        let cornerRadius: CGFloat = 5
        let path = NSBezierPath(roundedRect: selectionRect, xRadius: cornerRadius, yRadius: cornerRadius)
        let selectionColor = getSelectionColor?() ??  NSColor.controlBackgroundColor

        context.setFillColor(selectionColor.cgColor)
        path.fill()
    }
}
