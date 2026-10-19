//
//  MarkedTextManager.swift
//  TableProTextEngine
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

    /// Resolves the stored ranges against a document of `length`, dropping any that name no
    /// position in it and collapsing any that resolve to the same one.
    ///
    /// An input session spans many callbacks and this object has no hook for edits made through
    /// any other path, so an edit that shrinks the document leaves its ranges behind. Resolving
    /// before they are used keeps the next keystroke of a composition computed against text that
    /// still exists, rather than replacing at a position the document no longer has.
    func resolveRanges(inDocumentOfLength length: Int) {
        var resolved: [NSRange] = []
        for range in markedRanges {
            guard let clamped = range.resolved(inDocumentOfLength: length),
                  !resolved.contains(clamped) else {
                continue
            }
            resolved.append(clamped)
        }
        markedRanges = resolved
    }

    /// Marks the composition's text after it replaced `replacedRanges`, which are in the coordinates of the text
    /// before that replacement: each mark moves by what the ones before it added.
    /// - Parameters:
    ///   - insertLength: The length of the composition's text.
    ///   - replacedRanges: The ranges the composition's text replaced.
    func updateMarkedRanges(insertLength: Int, replacedRanges: [NSRange]) {
        var shift = 0
        markedRanges = replacedRanges.sorted(by: { $0.location < $1.location }).map { range in
            defer { shift += insertLength - range.length }
            return NSRange(location: range.location + shift, length: insertLength)
        }
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
