//
//  NSBezierPath+DrawableBounds.swift
//  CodeEditTextView
//

import AppKit

extension NSBezierPath {
    /// The bounding box of the path, or `nil` when the path has no elements.
    ///
    /// `bounds` raises `NSGenericException` for a path with no elements, and AppKit terminates the process when an
    /// exception escapes `draw(_:)`, so drawing code must never read `bounds` without knowing the path has elements.
    var drawableBounds: CGRect? {
        isEmpty ? nil : bounds
    }
}
