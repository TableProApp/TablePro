//
//  JsonFieldEditingModel.swift
//  TablePro
//

import Foundation

/// The editing model behind the row inspector's JSON field: what the editor shows, and when that
/// text and the stored value have to be reconciled.
///
/// It lives outside the view because the defect it exists to prevent is a fixpoint between two
/// mirrors of one value, and a fixpoint is only testable if it can be driven without a window.
///
/// The rule is ``lastSynced``: the editor's text and the stored value are known to agree at that
/// string, so a value arriving from the store that still means the same thing is this editor's own
/// write coming back and is ignored. What the field stages is a compacted form of what the editor
/// shows, so the two agree in meaning rather than in bytes, and a comparison against the editor's
/// displayed text cannot tell an echo from an external change on its own.
///
/// Adopting an echo is what let a keystroke be overwritten by the value it had just replaced, and
/// then pushed back, forever: one keystroke produced 6,944 body evaluations in 30 seconds at 100%
/// CPU, and the typed character was discarded (#3051).
internal struct JsonFieldEditingModel: Equatable, Sendable {
    private(set) var displayText: String

    /// The last text the editor published, in display form. Never the stored form, which has been
    /// through `JsonReindenter.normalize` and would compare unequal to everything the editor holds.
    private var lastSynced: String

    internal init(storedValue: String) {
        let opening = JsonReindenter.reindent(storedValue)
        self.displayText = opening
        self.lastSynced = opening
    }

    /// The user typed. Returns the value to write into the field's binding, or nil when the text
    /// already agrees with the store and writing it would only start another round.
    internal mutating func typed(_ text: String) -> String? {
        displayText = text
        guard text != lastSynced else { return nil }
        lastSynced = text
        return text
    }

    /// The field's binding delivered a value. Returns whether the editor adopted it.
    ///
    /// Anything that still means what ``lastSynced`` means is this editor's own write coming back,
    /// compacted by `MultiRowEditState` or dropped by it because the value matched the stored one
    /// again. Everything else is a real external change: Set NULL, Set DEFAULT, Set EMPTY, an SQL
    /// function, or a commit from the pop-out value window.
    ///
    /// `JsonReindenter.normalize` returns its source unchanged when the document does not parse, so
    /// a half-typed value is compared exactly rather than reported equal to something else.
    internal mutating func received(_ value: String) -> Bool {
        guard JsonReindenter.normalize(value) != JsonReindenter.normalize(lastSynced) else { return false }
        displayText = JsonReindenter.reindent(value)
        lastSynced = displayText
        return true
    }
}
