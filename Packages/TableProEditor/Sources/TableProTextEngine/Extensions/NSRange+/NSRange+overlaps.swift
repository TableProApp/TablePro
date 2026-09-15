//
//  NSRange+overlaps.swift
//  TableProTextEngine
//

import Foundation

extension NSRange {
    /// Whether the two ranges share a position, counting the position each one ends at.
    ///
    /// Closed at both ends on purpose. An emphasis may be empty, and a zero-length range sitting on a boundary still
    /// marks the text the range beside it covers, so an intersection test would drop it.
    func overlaps(_ other: NSRange) -> Bool {
        location <= other.max && other.location <= max
    }
}
