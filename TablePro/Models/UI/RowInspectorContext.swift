//
//  RowInspectorContext.swift
//  TablePro
//

import Foundation

/// Everything the inspector draws, and nothing else.
///
/// This used to be one `InspectorContext` carrying the row, the JSON snapshot and a ten-row text
/// summary of the grid for the assistant, so a selection change rebuilt the assistant's context and
/// an assistant change rebuilt the row's. Splitting them along the surfaces that read them is what
/// lets each be `Equatable`: the old struct held an untyped `[(column:value:type:)]` tuple array,
/// which no equality could be written for, so every rebuild was a change whether or not anything
/// had moved.
///
/// The fields themselves are not here. They live in `MultiRowEditState`, which both the data grid
/// and the schema grid already configure, and duplicating them into a second array is what made the
/// old tuple path dead computation: it ran the display-format and blob-format pipeline over every
/// cell on every tick and the view read only whether it was nil.
internal struct RowInspectorContext: Equatable {
    internal let subject: InspectorSubject

    /// Whether a row is selected at all, which the mode choice turns on. Separate from the subject
    /// because a subject exists for a table with no row selected.
    internal let hasRow: Bool

    internal let isEditable: Bool
    internal let isRowDeleted: Bool

    /// Present only on a tab that actually has a table. The old context handed over
    /// `coordinator.tableMetadata` unconditionally, and that slot is latest-wins and cleared only
    /// on teardown, so a query tab, a dashboard or an ER diagram showed the statistics of whichever
    /// table had been opened last, including after its tab was closed.
    internal let tableMetadata: TableMetadata?

    /// The same row the fields mode shows, as raw cell values, because the JSON mode decides from
    /// the column's own type whether a value prints quoted.
    internal let jsonRow: JSONRowSnapshot?

    /// The table a structure row's type picker offers user-defined types for. Nil outside one.
    internal let userDefinedTypeScope: DatabaseScope?

    internal static let empty = RowInspectorContext(
        subject: .empty,
        hasRow: false,
        isEditable: false,
        isRowDeleted: false,
        tableMetadata: nil,
        jsonRow: nil,
        userDefinedTypeScope: nil
    )
}

/// What the assistant needs to know about the window it is docked in.
///
/// Kept apart from the row context so that moving the selection does not rebuild it, and so that a
/// window whose assistant was never revealed never pays for the grid summary at all.
internal struct AssistantContext: Equatable {
    internal let currentQuery: String?
    internal let queryResults: String?

    internal static let empty = AssistantContext(currentQuery: nil, queryResults: nil)
}
