//
//  RangeStore+Internals.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 10/25/24
//

import _RopeModule

extension RangeStore {
    /// Coalesce items before and after the given range.
    ///
    /// Compares the next run with the run at the given range. If they're the same, removes the next run and grows the
    /// pointed-at run.
    /// Performs the same operation with the preceding run, with the difference that the pointed-at run is removed
    /// rather than the queried one.
    ///
    /// - Parameter range: The range of the item to coalesce around.
    mutating func coalesceNearby(range: Range<Int>) {
        var index = findIndex(at: range.lastIndex).index
        if index < rope.endIndex && rope.index(after: index) != rope.endIndex {
            coalesceRunAfter(index: &index)
        }

        index = findIndex(at: range.lowerBound).index
        if index > rope.startIndex && index < rope.endIndex && rope.count > 1 {
            index = rope.index(before: index)
            coalesceRunAfter(index: &index)
        }
    }

    /// Check if the run and the run after it are equal, and if so remove the next one and concatenate the two.
    private mutating func coalesceRunAfter(index: inout Index) {
        let thisRun = rope[index]
        let nextRun = rope[rope.index(after: index)]

        if thisRun.compareValue(nextRun) {
            rope.update(at: &index, by: { $0.length += nextRun.length })

            var nextIndex = index
            rope.formIndex(after: &nextIndex)
            rope.remove(at: nextIndex)
        }
    }
}
