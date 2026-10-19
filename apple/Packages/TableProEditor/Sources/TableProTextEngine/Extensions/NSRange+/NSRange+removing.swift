//
//  NSRange+removing.swift
//  TableProTextEngine
//

import Foundation

extension NSRange {
    /// This range in the document left once `removed` is taken out. `removed` holds disjoint ranges of the document
    /// before; any part of this range inside one of them goes with it.
    func removing(_ removed: [NSRange]) -> NSRange {
        func shifted(_ offset: Int) -> Int {
            offset - removed.reduce(0) { $0 + Swift.max(0, Swift.min($1.max, offset) - $1.location) }
        }
        let start = shifted(location)
        return NSRange(location: start, length: shifted(max) - start)
    }

    /// The characters this range shares with `other`, or `nil` when it shares none.
    func overlap(with other: NSRange) -> NSRange? {
        let start = Swift.max(location, other.location)
        let end = Swift.min(max, other.max)
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// The parts of this range outside `other`, in order.
    func subtracting(_ other: NSRange) -> [NSRange] {
        let before = NSRange(location: location, length: Swift.max(0, Swift.min(max, other.location) - location))
        let afterStart = Swift.max(location, other.max)
        let after = NSRange(location: afterStart, length: Swift.max(0, max - afterStart))
        return [before, after].filter { $0.length > 0 }
    }
}
