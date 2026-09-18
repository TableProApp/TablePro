import Foundation

public struct R2SQLResultSet: Sendable, Equatable {
    public let columns: [String]
    public let columnTypeNames: [String]
    public let rows: [[R2SQLValue]]

    public init(columns: [String], columnTypeNames: [String], rows: [[R2SQLValue]]) {
        self.columns = columns
        self.columnTypeNames = columnTypeNames
        self.rows = rows
    }
}

public enum R2SQLRowMapper {
    /// Rows arrive as objects keyed by column name, so the schema supplies the order and a key a
    /// row leaves out is a NULL.
    public static func map(_ result: R2SQLResult) -> R2SQLResultSet {
        let kinds = result.schema.map { R2SQLTypeMapper.valueKind($0.typeName) }
        let rows = result.rows.map { row in
            zip(result.schema, kinds).map { field, kind in R2SQLTypeMapper.cell(row[field.name], kind: kind) }
        }
        return R2SQLResultSet(
            columns: result.schema.map(\.name),
            columnTypeNames: result.schema.map { R2SQLTypeMapper.displayTypeName($0.typeName) },
            rows: rows
        )
    }
}
