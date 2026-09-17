//
//  AgentResultDecoder.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Turns a tool result back into rows the data grid can draw.
///
/// The transcript is the only record of what a session read, and it holds the tool result as the
/// JSON text the model was given. Decoding it here rather than keeping a second copy of the rows is
/// what lets a restored session's result pane be correct with no replay.
///
/// Decoding once per run and not per body evaluation matters: the transcript is rewritten every
/// 50ms while a reply streams, so a computed property doing this would re-parse every result the
/// conversation has ever produced, twenty times a second.
internal enum AgentResultDecoder {
    /// The bridge answers a query with `{"columns": [...], "rows": [[...]]}`, and encodes a cell as
    /// a JSON string, a number, a bool or null. Binary arrives base64-encoded as a string, which is
    /// what the grid would show for it anyway.
    internal static func tableRows(fromResultJSON json: String) -> TableRows? {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JsonValue.self, from: data),
              case .object(let payload) = decoded,
              case .array(let columnValues)? = payload["columns"],
              case .array(let rowValues)? = payload["rows"],
              !columnValues.isEmpty else { return nil }

        let columns: [String] = columnValues.map { value in
            guard case .string(let name) = value else { return "" }
            return name
        }
        let rows: [[PluginCellValue]] = rowValues.compactMap { rowValue in
            guard case .array(let cells) = rowValue else { return nil }
            return cells.map(cellValue)
        }
        guard !rows.isEmpty else { return nil }

        return TableRows.from(
            queryRows: rows,
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: columns.count)
        )
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
