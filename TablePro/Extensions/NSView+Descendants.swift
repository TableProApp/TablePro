//
//  NSView+Descendants.swift
//  TablePro
//

import AppKit

public extension NSView {
    /// The first view of a type in this subtree, in front-to-back subview order.
    ///
    /// How a focus command names a pane's key view. The panes are SwiftUI, so the view that takes
    /// the keyboard is built by a representable and handed to nobody: the app holds the hosting
    /// controller and never the `NSOutlineView` or `NSTextView` inside it. Asking the subtree is
    /// exact rather than approximate, because only the mounted pane is in it, which is what makes
    /// one question answer every sidebar layout and both sidebar tabs.
    func firstDescendant<V: NSView>(of type: V.Type) -> V? {
        for subview in subviews {
            if let match = subview as? V { return match }
            if let match = subview.firstDescendant(of: type) { return match }
        }
        return nil
    }

    /// The first view in this subtree that AppKit would let Tab land on.
    ///
    /// `canBecomeKeyView` is the same eligibility rule the key view loop applies, so a pane focused
    /// through this receives the keyboard on the view Tab would have reached anyway. It is the
    /// answer for a pane with no one obvious target, where naming a type would be a guess about
    /// what its first control happens to be today.
    var firstKeyViewDescendant: NSView? {
        for subview in subviews {
            if subview.canBecomeKeyView { return subview }
            if let match = subview.firstKeyViewDescendant { return match }
        }
        return nil
    }
}
