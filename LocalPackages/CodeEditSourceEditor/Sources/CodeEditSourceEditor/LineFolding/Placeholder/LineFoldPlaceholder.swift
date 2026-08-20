//
//  LineFoldPlaceholder.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/9/25.
//

import AppKit
import CodeEditTextView

protocol LineFoldPlaceholderDelegate: AnyObject {
    func placeholderBackgroundColor() -> NSColor
    func placeholderTextColor() -> NSColor

    func placeholderSelectedColor() -> NSColor
    func placeholderSelectedTextColor() -> NSColor

    func placeholderDiscarded(fold: FoldRange)
}

/// Used to display a folded region in a text document.
///
/// To stay up-to-date with the user's theme, it uses the ``LineFoldPlaceholderDelegate`` to query for current colors
/// to use for drawing.
class LineFoldPlaceholder: TextAttachment {
    /// The widest a placeholder grows before its label is clipped, in characters.
    static let maxWidthInCharacters: CGFloat = 60

    let fold: FoldRange
    let charWidth: CGFloat
    let label: String
    var isSelected: Bool = false
    weak var delegate: LineFoldPlaceholderDelegate?

    private let font: NSFont
    private let labelWidth: CGFloat

    init(delegate: LineFoldPlaceholderDelegate?, fold: FoldRange, charWidth: CGFloat, label: String, font: NSFont) {
        self.fold = fold
        self.delegate = delegate
        self.charWidth = charWidth
        self.label = label
        self.font = font
        self.labelWidth = label.isEmpty
            ? 0
            : (label as NSString).size(withAttributes: [.font: font]).width
    }

    var width: CGFloat {
        guard labelWidth > 0 else { return charWidth * 5 }
        return min(labelWidth + (charWidth * 3), charWidth * Self.maxWidthInCharacters)
    }

    func draw(in context: CGContext, rect: NSRect) {
        guard let delegate else { return }

        context.saveGState()
        defer { context.restoreGState() }

        let background = isSelected ? delegate.placeholderSelectedColor() : delegate.placeholderBackgroundColor()
        context.setFillColor(background.safeCGColor)
        context.addPath(
            NSBezierPath(
                rect: rect.transform(x: charWidth / 2, y: 2.0, width: -charWidth, height: -4.0),
                roundedCorners: .all,
                cornerRadius: rect.height / 2
            ).cgPathFallback
        )
        context.fillPath()

        let foreground = isSelected ? delegate.placeholderSelectedTextColor() : delegate.placeholderTextColor()
        guard !label.isEmpty else {
            drawEllipsis(in: context, rect: rect, color: foreground)
            return
        }

        drawLabel(in: context, rect: rect, color: foreground)
    }

    private func drawLabel(in context: CGContext, rect: NSRect, color: NSColor) {
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
        let available = rect.width - (charWidth * 2)
        guard available > 0 else { return }

        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)

        context.saveGState()
        defer { context.restoreGState() }

        context.clip(to: rect.transform(x: charWidth, width: -charWidth * 2))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(
            x: rect.minX + charWidth,
            y: rect.midY + ((ascent - descent) / 2)
        )
        CTLineDraw(line, context)
    }

    private func drawEllipsis(in context: CGContext, rect: NSRect, color: NSColor) {
        let size = charWidth / 2.5
        let centerY = rect.midY - (size / 2.0)

        context.setFillColor(color.safeCGColor)
        context.addEllipse(
            in: CGRect(x: rect.minX + (charWidth * 2) - size, y: centerY, width: size, height: size)
        )
        context.addEllipse(
            in: CGRect(x: rect.midX - (size / 2), y: centerY, width: size, height: size)
        )
        context.addEllipse(
            in: CGRect(x: rect.maxX - (charWidth * 2), y: centerY, width: size, height: size)
        )
        context.fillPath()
    }

    /// A placeholder stands in for code the reader wants back, so one click brings it back. The attachment manager
    /// removes the placeholder itself, and the delegate records the change; the gutter's chevron removes it through
    /// the layout manager instead. Both routes end at the same commit, so the two can never disagree.
    var activatesOnSingleClick: Bool { true }

    func attachmentAction() -> TextAttachmentAction {
        delegate?.placeholderDiscarded(fold: fold)
        return .discard
    }
}
