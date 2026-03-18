//
//  MinimapView+TextLayoutManagerDelegate.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 4/11/25.
//

import AppKit
import CodeEditTextView

extension MinimapView: TextLayoutManagerDelegate {
    public func layoutManagerHeightDidUpdate(newHeight: CGFloat) {
        updateContentViewHeight()
    }

    public func layoutManagerMaxWidthDidChange(newWidth: CGFloat) { }

    public func layoutManagerTypingAttributes() -> [NSAttributedString.Key: Any] {
        textView?.layoutManagerTypingAttributes() ?? [:]
    }

    public func textViewportSize() -> CGSize {
        var size = scrollView.contentSize
        size.height -= scrollView.contentInsets.top + scrollView.contentInsets.bottom
        size.width = textView?.layoutManager.maxLineLayoutWidth ?? size.width
        return size
    }

    public func layoutManagerYAdjustment(_ yAdjustment: CGFloat) {
        var point = scrollView.documentVisibleRect.origin
        point.y += yAdjustment
        scrollView.documentView?.scroll(point)
    }
}
