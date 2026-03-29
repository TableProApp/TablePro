//
//  TextLayoutManagerDelegate.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/10/25.
//

import AppKit

public protocol TextLayoutManagerDelegate: AnyObject {
    func layoutManagerHeightDidUpdate(newHeight: CGFloat)
    func layoutManagerMaxWidthDidChange(newWidth: CGFloat)
    func layoutManagerTypingAttributes() -> [NSAttributedString.Key: Any]
    func textViewportSize() -> CGSize
    func layoutManagerYAdjustment(_ yAdjustment: CGFloat)

    var visibleRect: NSRect { get }
}
