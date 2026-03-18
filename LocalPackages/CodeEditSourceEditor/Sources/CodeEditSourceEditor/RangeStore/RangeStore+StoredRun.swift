//
//  RangeStore+StoredRun.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 10/25/24

import _RopeModule

extension RangeStore {
    struct StoredRun {
        var length: Int
        let value: Element?

        static func empty(length: Int) -> Self {
            StoredRun(length: length, value: nil)
        }

        /// Compare two styled ranges by their stored styles.
        /// - Parameter other: The range to compare to.
        /// - Returns: The result of the comparison.
        func compareValue(_ other: Self) -> Bool {
            return if let lhs = value, let rhs = other.value {
                lhs == rhs
            } else if let lhs = value {
                lhs.isEmpty
            } else if let rhs = other.value {
                rhs.isEmpty
            } else {
                true
            }
        }
    }
}

extension RangeStore.StoredRun: RopeElement {
    typealias Index = Int

    var summary: Summary { Summary(length: length) }

    @inlinable
    var isEmpty: Bool { length == 0 }

    @inlinable
    var isUndersized: Bool { false } // Never undersized, pseudo-container

    func invariantCheck() {}

    mutating func rebalance(nextNeighbor right: inout Self) -> Bool {
        // Never undersized
        fatalError("Unimplemented")
    }

    mutating func rebalance(prevNeighbor left: inout Self) -> Bool {
        // Never undersized
        fatalError("Unimplemented")
    }

    mutating func split(at index: Self.Index) -> Self {
        assert(index >= 0 && index <= length)
        let tail = Self(length: length - index, value: value)
        length = index
        return tail
    }
}

extension RangeStore.StoredRun {
    struct Summary {
        var length: Int
    }
}

extension RangeStore.StoredRun.Summary: RopeSummary {
    // FIXME: This is entirely arbitrary. Benchmark this.
    @inline(__always)
    static var maxNodeSize: Int { 10 }

    @inline(__always)
    static var zero: RangeStore.StoredRun.Summary { Self(length: 0) }

    @inline(__always)
    var isZero: Bool { length == 0 }

    mutating func add(_ other: RangeStore.StoredRun.Summary) {
        length += other.length
    }

    mutating func subtract(_ other: RangeStore.StoredRun.Summary) {
        length -= other.length
    }
}
