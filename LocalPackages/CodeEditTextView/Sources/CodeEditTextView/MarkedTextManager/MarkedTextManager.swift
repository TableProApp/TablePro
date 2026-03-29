//
//  MarkedTextManager.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 11/7/23.
//

import AppKit

/// Manages marked ranges. Not a public API.
class MarkedTextManager {
    /// All marked ranges being tracked.
    private(set) var markedRanges: [NSRange] = []

    /// The attributes to use for marked text. Defaults to a single underline when `nil`
    var markedTextAttributes: [NSAttributedString.Key: Any] = [
        .underlineStyle: NSUnderlineStyle.single.rawValue
    ]

    /// True if there is marked text being tracked.
    var hasMarkedText: Bool {
        !markedRanges.isEmpty
    }

    /// Removes all marked ranges.
    func removeAll() {
        markedRanges.removeAll()
    }

    /// Updates the stored marked ranges.
    ///
    /// Two cases here:
    /// - No marked ranges yet:
    ///     - Create new marked ranges from the text selection, with the length of the text being inserted
    /// - Marked ranges exist:
    ///     - Update the existing marked ranges, using the original ranges as a reference. The marked ranges don't
    ///       change position, so we update each one with the new length and then move it to reflect each cursor's
    ///       added text.
    ///
    /// - Parameters:
    ///   - insertLength: The length of the string being inserted.
    ///   - textSelections: The current text selections.
    func updateMarkedRanges(insertLength: Int, textSelections: [NSRange]) {
        var cumulativeExistingDiff = 0
        var newRanges = [NSRange]()
        let ranges: [NSRange] = if markedRanges.isEmpty {
            textSelections.sorted(by: { $0.location < $1.location })
        } else {
            markedRanges.sorted(by: { $0.location < $1.location })
        }

        for range in ranges {
            newRanges.append(NSRange(location: range.location + cumulativeExistingDiff, length: insertLength))
            cumulativeExistingDiff += insertLength - range.length
        }
        markedRanges = newRanges
    }

    /// Finds any marked ranges for a line and returns them.
    /// - Parameter lineRange: The range of the line.
    /// - Returns: A `MarkedRange` struct with information about attributes and ranges. `nil` if there is no marked
    ///            text for this line.
    func markedRanges(in lineRange: NSRange) -> MarkedRanges? {
        let ranges = markedRanges.compactMap {
            $0.intersection(lineRange)
        }.map {
            NSRange(location: $0.location - lineRange.location, length: $0.length)
        }
        if ranges.isEmpty {
            return nil
        } else {
            return MarkedRanges(ranges: ranges, attributes: markedTextAttributes)
        }
    }

    /// Updates marked text ranges for a new set of selections.
    /// - Parameter textSelections: The new text selections.
    /// - Returns: `True` if the marked text needs layout.
    func updateForNewSelections(textSelections: [TextSelectionManager.TextSelection]) -> Bool {
        // Ensure every marked range has a matching selection.
        // If any marked ranges do not have a matching selection, unmark.
        // Matching, in this context, means having a selection in the range location...max
        var markedRanges = markedRanges
        for textSelection in textSelections {
            if let markedRangeIdx = markedRanges.firstIndex(where: {
                ($0.location...$0.max).contains(textSelection.range.location)
                && ($0.location...$0.max).contains(textSelection.range.max)
            }) {
                markedRanges.remove(at: markedRangeIdx)
            } else {
                return true
            }
        }

        // If any remaining marked ranges, we need to unmark.
        if !markedRanges.isEmpty {
            return false
        } else {
            return true
        }
    }
}
