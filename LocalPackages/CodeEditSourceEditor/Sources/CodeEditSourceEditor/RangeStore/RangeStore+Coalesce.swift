//
//  RangeStore+Internals.swift
//  CodeEditSourceEditor
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
        if index < _guts.endIndex && _guts.index(after: index) != _guts.endIndex {
            coalesceRunAfter(index: &index)
        }

        index = findIndex(at: range.lowerBound).index
        if index > _guts.startIndex && index < _guts.endIndex && _guts.count > 1 {
            index = _guts.index(before: index)
            coalesceRunAfter(index: &index)
        }
    }

    /// Check if the run and the run after it are equal, and if so remove the next one and concatenate the two.
    private mutating func coalesceRunAfter(index: inout Index) {
        let thisRun = _guts[index]
        let nextRun = _guts[_guts.index(after: index)]

        if thisRun.compareValue(nextRun) {
            _guts.update(at: &index, by: { $0.length += nextRun.length })

            var nextIndex = index
            _guts.formIndex(after: &nextIndex)
            _guts.remove(at: nextIndex)
        }
    }
}
