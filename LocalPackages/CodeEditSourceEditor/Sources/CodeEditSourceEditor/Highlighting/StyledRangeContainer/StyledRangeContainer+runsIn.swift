//
//  StyledRangeContainer+runsIn.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/18/25.
//

import Foundation

extension StyledRangeContainer {
    /// Coalesces all styled runs into a single continuous array of styled runs.
    ///
    /// When there is an overlapping, conflicting style (eg: provider 2 gives `.comment` to the range `0..<2`, and
    /// provider 1 gives `.string` to `1..<2`), the provider with a lower identifier will be prioritized. In the example
    /// case, the final value would be `0..<1=.comment` and `1..<2=.string`.
    ///
    /// - Parameter range: The range to query.
    /// - Returns: An array of continuous styled runs.
    func runsIn(range: NSRange) -> [RangeStoreRun<StyleElement>] {
        func combineLowerPriority(_ lhs: inout RangeStoreRun<StyleElement>, _ rhs: RangeStoreRun<StyleElement>) {
            lhs.value = lhs.value?.combineLowerPriority(rhs.value) ?? rhs.value
        }

        func combineHigherPriority(_ lhs: inout RangeStoreRun<StyleElement>, _ rhs: RangeStoreRun<StyleElement>) {
            lhs.value = lhs.value?.combineHigherPriority(rhs.value) ?? rhs.value
        }

        // Ordered by priority, lower = higher priority.
        var allRuns = _storage.values
            .sorted(by: { $0.priority < $1.priority })
            .map { $0.store.runs(in: range.intRange) }

        var runs: [RangeStoreRun<StyleElement>] = []
        var minValue = allRuns.compactMap { $0.last }.enumerated().min(by: { $0.1.length < $1.1.length })
        var counter = 0

        while let value = minValue {
            // Get minimum length off the end of each array
            let minRunIdx = value.offset
            var minRun = value.element

            for idx in (0..<allRuns.count).reversed() where idx != minRunIdx {
                guard let last = allRuns[idx].last else { continue }

                if idx < minRunIdx {
                    combineHigherPriority(&minRun, last)
                } else {
                    combineLowerPriority(&minRun, last)
                }

                if last.length == minRun.length {
                    allRuns[idx].removeLast()
                } else {
                    // safe due to guard a few lines above.
                    allRuns[idx][allRuns[idx].count - 1].subtractLength(minRun)
                }
            }

            if !allRuns[minRunIdx].isEmpty {
                allRuns[minRunIdx].removeLast()
            }

            assert(minRun.length > 0, "Empty or negative runs are not allowed.")
            runs.append(minRun)
            minValue = allRuns.compactMap { $0.last }.enumerated().min(by: { $0.1.length < $1.1.length })

            counter += 1
        }

        return runs.reversed()
    }
}
