//
//  NSRange+resolved.swift
//  CodeEditTextView
//

import Foundation

public extension NSRange {
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
