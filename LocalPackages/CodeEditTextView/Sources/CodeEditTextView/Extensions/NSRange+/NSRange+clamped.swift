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

    /// Returns the range resolved against a document of `length`, or `nil` when it names no
    /// position in that document.
    ///
    /// Use this for a range that came from outside the text view: an input service, an
    /// accessibility client, or state stored before an edit. Those may send `NSNotFound`, a
    /// negative value, or a length that overflows when added to the location, none of which
    /// ``clamped(toLength:)`` can move inside the document, and the second of which traps when
    /// `max` is computed.
    func resolved(inDocumentOfLength length: Int) -> NSRange? {
        guard location != NSNotFound,
              location >= 0,
              self.length >= 0,
              location <= Int.max - self.length else {
            return nil
        }
        return clamped(toLength: length)
    }
}
