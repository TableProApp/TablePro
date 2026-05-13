//
//  TextSelectionManager+Update.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 10/22/23.
//

import Foundation

extension TextSelectionManager {
    public func didReplaceCharacters(in range: NSRange, replacementLength: Int) {
        // Net shift = chars added - chars removed. Selections past `range.max` move by this delta.
        // The previous formula short-circuited to `replacementLength` when non-zero, which dropped
        // the chars-removed term and over-shifted selections after a same-length replace (e.g. the
        // multi-cursor IME path replaces each marked range char-for-char).
        let delta = replacementLength - range.length
        for textSelection in self.textSelections {
            if textSelection.range.location > range.max {
                textSelection.range.location = max(0, textSelection.range.location + delta)
                textSelection.range.length = 0
            } else if textSelection.range.intersection(range) != nil
                        || textSelection.range == range
                        || (textSelection.range.isEmpty && textSelection.range.location == range.max) {
                if replacementLength > 0 {
                    textSelection.range.location = range.location + replacementLength
                } else {
                    textSelection.range.location = range.location
                }
                textSelection.range.length = 0
            } else {
                textSelection.range.length = 0
            }
        }

        // Clean up duplicate selection ranges
        var allRanges: Set<NSRange> = []
        for (idx, selection) in self.textSelections.enumerated().reversed() {
            if allRanges.contains(selection.range) {
                self.textSelections.remove(at: idx)
            } else {
                allRanges.insert(selection.range)
            }
        }
    }

    public func notifyAfterEdit(force: Bool = false) {
        updateSelectionViews(force: force)
        NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))
    }
}
