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
        let isLightMode = (theme.background.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0.0) > 0.5

        // Set the line color based on the theme
        let lineColor = isLightMode ?
            NSColor.black.withAlphaComponent(0.075) :
            NSColor.white.withAlphaComponent(0.175)

        // Set the shaded area color (slightly more transparent)
        let shadedColor = isLightMode ?
            NSColor.black.withAlphaComponent(0.025) :
            NSColor.white.withAlphaComponent(0.025)

        // Draw the vertical line along the view's leading edge. The view's frame already stands on the column, so
        // drawing is done in bounds: using the frame's origin here would offset the line by the column a second time.
        lineColor.setStroke()
        let linePath = NSBezierPath()
        let lineX = bounds.minX + 0.5
        linePath.move(to: NSPoint(x: lineX, y: bounds.maxY))
        linePath.line(to: NSPoint(x: lineX, y: bounds.minY))
        linePath.lineWidth = 1.0
        linePath.stroke()

        // Draw the shaded area to the right of the line
        shadedColor.setFill()
        bounds.fill()
    }

    func updatePosition(in controller: TextViewController) {
        // The column's x in the text view, converted into the floating container this view is drawn in, so the guide
        // lands on the column however that container is offset from the document.
        guard let scrollView = controller.scrollView, let container = superview else { return }
        let columnX = controller.textView.layoutManager.edgeInsets.left + CGFloat(column) * controller.font.charWidth
        let xPosition = container.convert(NSPoint(x: columnX, y: 0), from: controller.textView).x
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
