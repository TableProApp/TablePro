//
//  NSRange+ClampToText.swift
//  TablePro
//

import Foundation

internal extension NSRange {
    /// Moves the range inside `0..<length`, keeping as much of it as still fits.
    ///
    /// A selection restored from disk was measured against the text as it was when the tab was
    /// saved. The query can be shorter now, so the saved range has to be clamped against the text
    /// the editor actually holds before it is applied.
    func clampedToTextLength(_ length: Int) -> NSRange {
        let start = Swift.min(Swift.max(location, 0), length)
        let end = Swift.min(Swift.max(location + self.length, 0), length)
        return NSRange(location: start, length: Swift.max(0, end - start))
    }
}
