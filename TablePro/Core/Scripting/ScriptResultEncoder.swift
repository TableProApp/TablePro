//
//  ScriptResultEncoder.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Turns a result set into the `query result` record the scripting dictionary declares.
///
/// The shape is forced by what Cocoa Scripting can carry. A list of lists cannot be returned at all,
/// under any declaration, but a record whose property is a list of records can, so rows are a list
/// of `result row` records each holding a flat list of text. Every key has to match the `cocoa key`
/// in `TablePro.sdef` exactly; a key that does not match is dropped from the record without an error,
/// which is why they come from `ScriptingKeys` rather than being spelled out here.
///
/// Cells become text because AppleScript has no null and no typed cell. A NULL is the empty string,
/// and binary is Base64, the same spelling the MCP surface uses so a script and a tool agree about
/// what a blob looks like.
internal enum ScriptResultEncoder {
    /// The metadata comes from the result set the tab is showing, not from defaults. `rows affected`,
    /// `truncated`, `execution time` and `status message` are declared properties, so answering them
    /// with zeros would describe a capped read as complete and a DML statement as having changed
    /// nothing.
    /// What the result set reports about itself, read on the main actor by the caller because
    /// `ResultSet` is main-actor isolated and this encoder is not.
    internal struct Metadata: Sendable {
        internal let rowsAffected: Int
        internal let truncated: Bool
        internal let executionTimeMs: Double
        internal let statusMessage: String?

        internal static let none = Metadata(
            rowsAffected: 0, truncated: false, executionTimeMs: 0, statusMessage: nil
        )
    }

    internal static func encode(
        _ read: DisplayedResultReader.Output,
        metadata: Metadata
    ) -> [String: Any] {
        record(
            columns: read.columns,
            rows: read.rows,
            rowsAffected: metadata.rowsAffected,
            truncated: metadata.truncated,
            executionTimeMs: metadata.executionTimeMs,
            statusMessage: metadata.statusMessage,
            results: []
        )
    }

    /// What `run query` answered. The record itself is the first result, as it always was; `results` lists every
    /// result set once a SQL Server script returned more than one, and is empty otherwise.
    internal static func encode(_ outcome: DatabaseAccessBridge.ScriptOutcome) -> [String: Any] {
        let primary = outcome.primary
        return record(
            columns: primary.columns,
            rows: primary.rows,
            rowsAffected: primary.rowsAffected,
            truncated: primary.isTruncated,
            executionTimeMs: outcome.executionTimeMs,
            statusMessage: primary.statusMessage,
            results: outcome.resultSets.count > 1 ? outcome.resultSets.map(resultSet(of:)) : []
        )
    }

    internal static func empty() -> [String: Any] {
        record(
            columns: [],
            rows: [],
            rowsAffected: 0,
            truncated: false,
            executionTimeMs: 0,
            statusMessage: nil,
            results: []
        )
    }

    private static func record(
        columns: [String],
        rows: [[PluginCellValue]],
        rowsAffected: Int,
        truncated: Bool,
        executionTimeMs: Double,
        statusMessage: String?,
        results: [[String: Any]]
    ) -> [String: Any] {
        [
            ScriptingKeys.QueryResult.columns: columns,
            ScriptingKeys.QueryResult.rows: rowRecords(rows),
            ScriptingKeys.QueryResult.rowCount: rows.count,
            ScriptingKeys.QueryResult.rowsAffected: rowsAffected,
            ScriptingKeys.QueryResult.truncated: truncated,
            ScriptingKeys.QueryResult.executionTime: executionTimeMs,
            ScriptingKeys.QueryResult.statusMessage: statusMessage ?? "",
            ScriptingKeys.QueryResult.results: results
        ]
    }

    private static func resultSet(of result: QueryResult) -> [String: Any] {
        [
            ScriptingKeys.QueryResult.columns: result.columns,
            ScriptingKeys.QueryResult.rows: rowRecords(result.rows),
            ScriptingKeys.QueryResult.rowCount: result.rows.count,
            ScriptingKeys.QueryResult.truncated: result.isTruncated,
            ScriptingKeys.QueryResult.statusMessage: result.statusMessage ?? ""
        ]
    }

    private static func rowRecords(_ rows: [[PluginCellValue]]) -> [[String: Any]] {
        rows.map { row in [ScriptingKeys.ResultRow.values: row.map(text(of:))] }
    }

    internal static func text(of cell: PluginCellValue) -> String {
        switch cell {
        case .null: ""
        case .text(let value): value
        case .bytes(let data): data.base64EncodedString()
        }
    }
}
