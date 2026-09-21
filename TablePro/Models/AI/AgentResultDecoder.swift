//
//  AgentResultDecoder.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What one query the session ran gave back, in the terms the result column answers in.
///
/// An optional could say rows or nothing, and nothing was three different answers: a statement that
/// returns no result set, such as an approved UPDATE, a reply the grid cannot read, and a query whose
/// result set was empty. The column read all three as "This query returned no rows.", so a write
/// that changed rows looked like a query that had matched none.
internal enum AgentResultPayload {
    /// A result set with rows in it.
    case rows(TableRows)
    /// A result set with no rows, which is an answer rather than a failure.
    case noRows
    /// A statement that returns no result set, and the rows it changed when the reply says. The bridge
    /// always sends the count, so a nil comes only from a tool that answers in the same shape without
    /// one.
    case completed(rowsAffected: Int?)
    /// A reply that is not a result the grid can read, which only a tool answering in prose sends.
    case unreadable
}

/// Turns a tool result back into what the result column draws.
///
/// The transcript is the only record of what a session read, and it holds the tool result as the
/// JSON text the model was given. Decoding it here rather than keeping a second copy of the rows is
/// what lets a restored session's result pane be correct with no replay.
///
/// Decoding once per run and not per body evaluation matters: the transcript changes all the while a
/// reply streams, and a computed property doing this would parse the selected run's whole result on
/// every one of those redraws. `AgentArtifactCache` is what keeps to that: it decodes a run the first
/// time the column asks for it and keeps the answer.
internal enum AgentResultDecoder {
    /// The bridge answers with `{"columns": [...], "rows": [[...]], "rows_affected": n}`, and encodes
    /// a cell as a JSON string, a number, a bool or null. Binary arrives base64-encoded as a string,
    /// which is what the grid would show for it anyway.
    ///
    /// The columns are what tell a write from an empty query. A statement with no result set comes
    /// back with none, and a query that matched nothing still names its columns.
    internal static func payload(fromResultJSON json: String) -> AgentResultPayload {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JsonValue.self, from: data),
              case .object(let payload) = decoded,
              case .array(let columnValues)? = payload["columns"],
              case .array(let rowValues)? = payload["rows"] else { return .unreadable }

        guard !columnValues.isEmpty else {
            guard rowValues.isEmpty else { return .unreadable }
            return .completed(rowsAffected: payload["rows_affected"]?.intValue)
        }

        let columns: [String] = columnValues.map { value in
            guard case .string(let name) = value else { return "" }
            return name
        }
        var rows: [[PluginCellValue]] = []
        rows.reserveCapacity(rowValues.count)
        for rowValue in rowValues {
            guard case .array(let cells) = rowValue else { return .unreadable }
            rows.append(cells.map(cellValue))
        }
        guard !rows.isEmpty else { return .noRows }

        return .rows(TableRows.from(
            queryRows: rows,
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: columns.count)
        ))
    }

    private static func cellValue(_ value: JsonValue) -> PluginCellValue {
        switch value {
        case .null: .null
        case .string(let text): .text(text)
        case .int(let number): .text(String(number))
        case .double(let number): .text(String(number))
        case .bool(let flag): .text(flag ? "true" : "false")
        case .array, .object: .text(value.jsonString(prettyPrinted: false))
        }
    }
}
