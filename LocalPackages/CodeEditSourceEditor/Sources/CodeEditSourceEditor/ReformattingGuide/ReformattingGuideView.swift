//
//  ReformattingGuideView.swift
//  CodeEditSourceEditor
//
//  Created by Austin Condiff on 4/28/25.
//

import AppKit
import CodeEditTextView

class ReformattingGuideView: NSView {
    @Invalidating(.display)
    var column: Int = 80

    var theme: EditorTheme {
        didSet { needsDisplay = true }
    }

    convenience init(configuration: borrowing SourceEditorConfiguration) {
        self.init(
            column: configuration.behavior.reformatAtColumn,
            theme: configuration.appearance.theme
        )
    }

    init(column: Int = 80, theme: EditorTheme) {
        self.column = column
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    // Draw the reformatting guide line and shaded area
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Determine if we should use light or dark colors based on the theme's background color
        let isLightMode = theme.background.brightnessComponent > 0.5

        // Set the line color based on the theme
        let lineColor = isLightMode ?
            NSColor.black.withAlphaComponent(0.075) :
            NSColor.white.withAlphaComponent(0.175)

        // Set the shaded area color (slightly more transparent)
        let shadedColor = isLightMode ?
            NSColor.black.withAlphaComponent(0.025) :
            NSColor.white.withAlphaComponent(0.025)

        // Draw the vertical line (accounting for inverted Y coordinate system)
        lineColor.setStroke()
        let linePath = NSBezierPath()
        linePath.move(to: NSPoint(x: frame.minX, y: frame.maxY))  // Start at top
        linePath.line(to: NSPoint(x: frame.minX, y: frame.minY))  // Draw down to bottom
        linePath.lineWidth = 1.0
        linePath.stroke()

        // Draw the shaded area to the right of the line
        shadedColor.setFill()
        let shadedRect = NSRect(
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: frame.height
        )
        shadedRect.fill()
    }

    func updatePosition(in controller: TextViewController) {
        // Calculate the x position based on the font's character width and column number
        let xPosition = (
            CGFloat(column) * (controller.font.charWidth / 2) // Divide by 2 to account for coordinate system
            + (controller.textViewInsets.left / 2)
        )

        // Get the scroll view's content size
        guard let scrollView = controller.scrollView else { return }
        let contentSize = scrollView.documentVisibleRect.size

        // Ensure we don't create an invalid frame
        let maxWidth = max(0, contentSize.width - xPosition)

        // Update the frame to be a vertical line at the specified column with a shaded area to the right
        let newFrame = NSRect(
            x: xPosition,
            y: 0,  // Start above the visible area
            width: maxWidth,
            height: contentSize.height  // Use extended height
        ).pixelAligned

        frame = newFrame
        needsDisplay = true
    }
}
