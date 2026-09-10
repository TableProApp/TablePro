//
//  NSRange+clamped.swift
//  CodeEditTextView
//

import Foundation

extension NSRange {
    /// Returns the range moved inside `0..<length`, keeping as much of it as still fits.
    ///
    /// Text can shrink under a selection, when a document is replaced with a shorter one. Dropping
    /// a range that no longer fits leaves the view with no selection at all, and no insertion point
    /// to select from; clamping keeps a usable selection at the end of the new text.
    func clamped(toLength length: Int) -> NSRange {
        let start = Swift.min(Swift.max(self.location, 0), length)
        let end = Swift.min(Swift.max(self.max, 0), length)
        return NSRange(location: start, length: Swift.max(0, end - start))
    }
}
