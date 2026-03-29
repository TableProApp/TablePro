//
//  TextView+TextLayoutManagerDelegate.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/15/23.
//

import AppKit

extension TextView: TextLayoutManagerDelegate {
    public func layoutManagerHeightDidUpdate(newHeight: CGFloat) {
        updateFrameIfNeeded()
    }

    public func layoutManagerMaxWidthDidChange(newWidth: CGFloat) {
        updateFrameIfNeeded()
    }

    public func layoutManagerTypingAttributes() -> [NSAttributedString.Key: Any] {
        typingAttributes
    }

    public func textViewportSize() -> CGSize {
        if let scrollView = scrollView {
            var size = scrollView.contentSize
            size.height -= scrollView.contentInsets.top + scrollView.contentInsets.bottom
            return size
        } else {
            return CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
        }
    }

    public func layoutManagerYAdjustment(_ yAdjustment: CGFloat) {
        var point = scrollView?.documentVisibleRect.origin ?? .zero
        point.y += yAdjustment
        scrollView?.documentView?.scroll(point)
    }
}
