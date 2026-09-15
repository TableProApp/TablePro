//
//  TextLayoutManagerDelegate.swift
//  TableProTextEngine
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

    /// Called at the end of a layout pass with the span that pass laid out and the span whose geometry it changed.
    ///
    /// This is the one signal that text geometry has moved. Anything keeping its own geometry over the text updates
    /// it from here rather than from a drawing call, which says nothing about whether layout changed.
    func layoutManagerDidLayout(_ update: TextLayoutUpdate)

    var visibleRect: NSRect { get }
}

public extension TextLayoutManagerDelegate {
    func layoutManagerDidLayout(_ update: TextLayoutUpdate) { }
}
