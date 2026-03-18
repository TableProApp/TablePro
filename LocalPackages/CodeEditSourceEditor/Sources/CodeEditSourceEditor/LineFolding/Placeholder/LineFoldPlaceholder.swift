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
    let fold: FoldRange
    let charWidth: CGFloat
    var isSelected: Bool = false
    weak var delegate: LineFoldPlaceholderDelegate?

    init(delegate: LineFoldPlaceholderDelegate?, fold: FoldRange, charWidth: CGFloat) {
        self.fold = fold
        self.delegate = delegate
        self.charWidth = charWidth
    }

    var width: CGFloat {
        charWidth * 5
    }

    func draw(in context: CGContext, rect: NSRect) {
        context.saveGState()

        guard let delegate else { return }

        let size = charWidth / 2.5
        let centerY = rect.midY - (size / 2.0)

        if isSelected {
            context.setFillColor(delegate.placeholderSelectedColor().cgColor)
        } else {
            context.setFillColor(delegate.placeholderBackgroundColor().cgColor)
        }

        context.addPath(
            NSBezierPath(
                rect: rect.transform(x: charWidth, y: 2.0, width: -charWidth * 2, height: -4.0),
                roundedCorners: .all,
                cornerRadius: rect.height / 2
            ).cgPathFallback
        )
        context.fillPath()

        if isSelected {
            context.setFillColor(delegate.placeholderSelectedTextColor().cgColor)
        } else {
            context.setFillColor(delegate.placeholderTextColor().cgColor)
        }
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

        context.restoreGState()
    }

    func attachmentAction() -> TextAttachmentAction {
        delegate?.placeholderDiscarded(fold: fold)
        return .discard
    }
}
