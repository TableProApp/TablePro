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

    /// The statement in the tab's query that produced these rows, kept so selecting this result can
    /// take the reader back to it. Nil for rows no editor statement stands behind: a table tab's
    /// load, a page turn, a sort, and anything else the app wrote itself.
    ///
    /// Like `origin` this describes the result rather than the tab, and like `origin` something
    /// reads it, which is what earns it a place here.
    var statementAnchor: StatementAnchor?

    /// An EXPLAIN result is a result set like any other, so it rides the same tab strip, pinning
    /// and history. It carries a plan instead of rows.
    var queryPlan: QueryPlan?
    var explainRawText: String?

    var isExplainResult: Bool { explainRawText != nil }

    var resultColumns: [String] { tableRows.columns }

    /// What to call a result on its tab.
    ///
    /// The table it came from is the clearest name and wins. Failing that the statement names itself, which is the
    /// whole reason the anchor keeps a bounded copy of the text: a strip reading "Result 1, Result 2, Result 3" tells
    /// the reader nothing about which is which. The counter is the last resort, for rows no statement stands behind.
    static func label(tableName: String?, anchor: StatementAnchor?, index: Int) -> String {
        if let tableName, !tableName.isEmpty { return tableName }
        if let statementLabel = anchor?.label, !statementLabel.isEmpty { return statementLabel }
        return String(format: String(localized: "Result %d"), index + 1)
    }

    init(id: UUID = UUID(), label: String, tableRows: TableRows = TableRows()) {
        self.id = id
        self.label = label
        self.tableRows = tableRows
    }
}
