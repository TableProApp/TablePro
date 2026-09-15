//
//  RangeStore.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 10/24/24
//

import _RopeModule
import Foundation

/// RangeStore is a container type that allows for setting and querying values for relative ranges in text. The
/// container reflects a text document in that its length needs to be kept up-to-date. It can efficiently remove and
/// replace subranges even for large documents. Provides helper methods for keeping some state in-sync with a text
/// document's content.
///
/// Internally this class uses a `Rope` from the swift-collections package, allowing for efficient updates and
/// retrievals.
struct RangeStore<Element: RangeStoreElement>: Sendable {
    typealias Run = RangeStoreRun<Element>
    typealias RopeType = Rope<StoredRun>
    typealias Index = RopeType.Index
    var rope = RopeType()

    var length: Int {
        rope.count(in: OffsetMetric())
    }

    /// A small performance improvement for multiple identical queries, as often happens when used
    /// in ``StyledRangeContainer``
    private var cache: (range: Range<Int>, runs: [Run])?

    init(documentLength: Int) {
        self.rope = RopeType([StoredRun(length: documentLength, value: nil)])
    }

    // MARK: - Core

    /// Find all runs in a range.
    /// - Parameter range: The range to query.
    /// - Returns: A continuous array of runs representing the queried range.
    func runs(in range: Range<Int>) -> [Run] {
        let length = rope.count(in: OffsetMetric())
        assert(range.lowerBound >= 0, "Negative lowerBound")
        assert(range.upperBound <= length, "upperBound outside valid range")
        if let cache, cache.range == range {
            return cache.runs
        }

        var runs = [Run]()
        var index = findIndex(at: range.lowerBound).index
        var offset: Int = range.lowerBound - rope.offset(of: index, in: OffsetMetric())
        var remainingLength = range.upperBound - range.lowerBound

        while index < rope.endIndex,
              rope.offset(of: index, in: OffsetMetric()) < range.upperBound,
              remainingLength > 0 {
            let run = rope[index]
            let runLength = min(run.length - offset, remainingLength)
            runs.append(Run(length: runLength, value: run.value))

            remainingLength -= runLength
            if remainingLength <= 0 {
                break // Avoid even checking the storage for the next index
            }
            index = rope.index(after: index)
            offset = 0
        }

        return runs
    }

    /// Sets a value for a range.
    /// - Parameters:
    ///   - value: The value to set for the given range.
    ///   - range: The range to write to.
    mutating func set(value: Element, for range: Range<Int>) {
        assert(range.lowerBound >= 0, "Negative lowerBound")
        assert(range.upperBound <= rope.count(in: OffsetMetric()), "upperBound outside valid range")
        set(runs: [Run(length: range.length, value: value)], for: range)
    }

    /// Replaces a range in the document with an array of runs.
    /// - Parameters:
    ///   - runs: The runs to insert.
    ///   - range: The range to replace.
    mutating func set(runs: [Run], for range: Range<Int>) {
        let gutsRange = 0..<length
        if range.clamped(to: gutsRange) != range {
            let upperBound = range.clamped(to: gutsRange).upperBound
            let missingCharacters = range.upperBound - upperBound
            storageUpdated(replacedCharactersIn: upperBound..<upperBound, withCount: missingCharacters)
        }

        // This is quite slow in debug builds but is a *really* important assertion for internal state.
        assert(!runs.contains(where: { $0.length < 0 }), "Runs cannot have negative length.")

        rope.replaceSubrange(
            range,
            in: OffsetMetric(),
            with: runs.map { StoredRun(length: $0.length, value: $0.value) }
        )

        coalesceNearby(range: range)
        cache = nil
    }
}

// MARK: - Storage Sync

extension RangeStore {
    /// Handles keeping the internal storage in sync with the document.
    mutating func storageUpdated(editedRange: NSRange, changeInLength delta: Int) {
        let storageRange: Range<Int>
        let newLength: Int

        if editedRange.length == 0 { // Deleting, editedRange is at beginning of the range that was deleted
            storageRange = editedRange.location..<(editedRange.location - delta)
            newLength = 0
        } else { // Replacing or inserting
            storageRange = editedRange.location..<(editedRange.location + editedRange.length - delta)
            newLength = editedRange.length
        }

        storageUpdated(
            replacedCharactersIn: storageRange.clamped(to: 0..<rope.count(in: OffsetMetric())),
            withCount: newLength
        )
    }

    /// Handles keeping the internal storage in sync with the document.
    mutating func storageUpdated(replacedCharactersIn range: Range<Int>, withCount newLength: Int) {
        assert(range.lowerBound >= 0, "Negative lowerBound")
        assert(range.upperBound <= rope.count(in: OffsetMetric()), "upperBound outside valid range")

        if newLength != 0 {
            rope.replaceSubrange(range, in: OffsetMetric(), with: [.empty(length: newLength)])
        } else {
            rope.removeSubrange(range, in: OffsetMetric())
        }

        if !rope.isEmpty {
            // Coalesce nearby items if necessary.
            coalesceNearby(range: Range(lowerBound: range.lowerBound, length: newLength))
        }

        cache = nil
    }
}
