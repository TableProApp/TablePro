import Foundation

/// The request lines a grid save sends, one atomic row mutation per changed row. `.absent` is a
/// cell the row has none of: left out of a new row, deleted from an existing one.
public enum BigtableRowWrites {
    public static func insert(table: String, columns: [String], values: [BigtableRowSet.Cell]) throws -> BigtableRequest {
        var key: Data?
        var cells: [String: Any] = [:]
        for (column, value) in zip(columns, values) {
            if column == BigtableRowSet.keyColumn {
                key = try self.key(value)
            } else if let text = text(value) {
                cells[column] = text
            }
        }
        guard let key else {
            throw BigtableError.configuration(String(localized: "Enter a _key for the new row. Bigtable has no generated keys."))
        }
        guard !cells.isEmpty else {
            throw BigtableError.configuration(String(localized: "A new row needs at least one cell. Bigtable does not store empty rows."))
        }
        return BigtableRequest(verb: .insert, table: table, key: key, body: try body(cells))
    }

    public static func update(table: String, key: Data, changes: [(column: String, value: BigtableRowSet.Cell)]) throws -> BigtableRequest? {
        guard !changes.contains(where: { $0.column == BigtableRowSet.keyColumn }) else {
            throw BigtableError.unsupported(String(localized: "A row key cannot change. Duplicate the row, give the copy a new _key, then delete this one."))
        }
        guard !changes.isEmpty else { return nil }
        var cells: [String: Any] = [:]
        for change in changes {
            cells[change.column] = text(change.value) ?? NSNull()
        }
        return BigtableRequest(verb: .put, table: table, key: key, body: try body(cells))
    }

    public static func delete(table: String, key: Data) -> BigtableRequest {
        BigtableRequest(verb: .delete, table: table, key: key)
    }

    public static func key(_ cell: BigtableRowSet.Cell) throws -> Data? {
        switch cell {
        case .absent: return nil
        case .bytes(let data): return data.isEmpty ? nil : data
        case .text(let text): return text.isEmpty ? nil : try BigtableBytes.parse(text)
        }
    }

    /// Bytes go back as `b64:` text, which a write reads back to the same bytes.
    private static func text(_ cell: BigtableRowSet.Cell) -> String? {
        switch cell {
        case .absent: return nil
        case .text(let text): return text
        case .bytes(let data): return BigtableBytes.base64Prefix + data.base64EncodedString()
        }
    }

    private static func body(_ cells: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: cells, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }
}
