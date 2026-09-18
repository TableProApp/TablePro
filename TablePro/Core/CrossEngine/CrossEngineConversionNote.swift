//
//  CrossEngineConversionNote.swift
//  TablePro
//
//  One thing the copy could not carry across unchanged.
//
//  Every note is produced before anything runs and read out in the review step,
//  because a conversion the user finds out about afterwards is indistinguishable
//  from a bug. A copy that says "TIMESTAMPTZ became DATETIME and the offset was
//  dropped" is a decision; the same copy in silence is data loss.
//

import Foundation

internal struct CrossEngineConversionNote: Identifiable, Hashable, Sendable {
    internal let table: String
    /// The column or index this is about. Empty for something about the table itself.
    internal let subject: String
    /// What changed, in the form the review step lists: `created_at: TIMESTAMPTZ → DATETIME`.
    internal let summary: String
    internal let reason: String
    internal let fidelity: CanonicalTypeFidelity

    internal init(
        table: String,
        subject: String,
        summary: String,
        reason: String,
        fidelity: CanonicalTypeFidelity
    ) {
        self.table = table
        self.subject = subject
        self.summary = summary
        self.reason = reason
        self.fidelity = fidelity
    }

    internal var id: String { "\(table)\u{1F}\(subject)\u{1F}\(summary)" }

    /// Whether the note is about something the user may want to change their mind over, rather
    /// than a widening that keeps every value.
    internal var isLossy: Bool { fidelity >= .approximated }
}

internal extension Array where Element == CrossEngineConversionNote {
    /// Lossy first, then by table and subject, so the review step opens on the ones that matter.
    var orderedForReview: [CrossEngineConversionNote] {
        sorted { lhs, rhs in
            guard lhs.fidelity == rhs.fidelity else { return lhs.fidelity > rhs.fidelity }
            guard lhs.table == rhs.table else { return lhs.table < rhs.table }
            return lhs.subject < rhs.subject
        }
    }
}
