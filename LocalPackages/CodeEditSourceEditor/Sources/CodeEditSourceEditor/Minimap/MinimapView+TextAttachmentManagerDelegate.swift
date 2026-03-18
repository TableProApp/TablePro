//
//  MinimapView+TextAttachmentManagerDelegate.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 6/25/25.
//

import AppKit
import CodeEditTextView

extension MinimapView: TextAttachmentManagerDelegate {
    class MinimapAttachment: TextAttachment {
        var isSelected: Bool = false
        var width: CGFloat

        init(_ other: TextAttachment, widthRatio: CGFloat) {
            self.width = other.width * widthRatio
        }

        func draw(in context: CGContext, rect: NSRect) { }
    }

    public func textAttachmentDidAdd(_ attachment: TextAttachment, for range: NSRange) {
        layoutManager?.attachments.add(MinimapAttachment(attachment, widthRatio: editorToMinimapWidthRatio), for: range)
    }

    public func textAttachmentDidRemove(_ attachment: TextAttachment, for range: NSRange) {
        layoutManager?.attachments.remove(atOffset: range.location)
    }
}
