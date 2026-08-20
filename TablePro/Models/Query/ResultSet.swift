//
//  ResultSet.swift
//  TablePro
//
//  A single result set from one SQL statement execution.
//

import Foundation
import Observation
import os

/// One execution's product: its rows, and the facts about how they were produced.
///
/// This is not where view state lives. A `ResultSet` is rebuilt with a fresh `id` on every table
/// load, page turn, sort and re-execute, and `TabDisplayState.replaceUnpinnedResults(with:)` drops
/// the one it replaces, so anything kept here is gone the first time the user turns a page.
/// `QueryTab` owns what has to outlive a single result: sort, pagination, column layout, chart
/// configuration and filters.
///
/// It used to mirror the first three of those, along with the tab's table name, editability and
/// metadata version. Nothing read any of them, and having them here made this look like the
/// established home for per-result view state, which is how the chart configuration nearly ended
/// up here (#2243). `origin` is the one of those facts that earns its place: it describes this
/// result rather than the tab, and the switch reads it.
@MainActor
@Observable
final class ResultSet: Identifiable {
    let id: UUID
    var label: String
    var tableRows: TableRows
    var executionTime: TimeInterval?
    var rowsAffected: Int = 0
    var errorMessage: String?
    var statusMessage: String?
    var isPinned: Bool = false
    var isTruncated: Bool = false
    var baseQuery: String?
    var baseQueryParameterValues: [String?]?

    /// The table these rows came from, captured when the statement ran. Nil means the rows have no
    /// single writable table, which `ResultEditability` treats as a refusal rather than a licence
    /// to use whatever the tab is pointing at now.
    var origin: ResultOrigin?

    /// An EXPLAIN result is a result set like any other, so it rides the same tab strip, pinning
    /// and history. It carries a plan instead of rows.
    var queryPlan: QueryPlan?
    var explainRawText: String?

    var isExplainResult: Bool { explainRawText != nil }

    var resultColumns: [String] { tableRows.columns }

    init(id: UUID = UUID(), label: String, tableRows: TableRows = TableRows()) {
        self.id = id
        self.label = label
        self.tableRows = tableRows
    }
}
