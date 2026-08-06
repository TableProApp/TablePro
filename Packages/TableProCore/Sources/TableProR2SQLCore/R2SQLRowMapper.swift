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

    public static let empty = R2SQLResultSet(columns: [], columnTypeNames: [], rows: [])
}

public enum R2SQLRowMapper {
    public static func map(_ result: R2SQLResult) -> R2SQLResultSet {
        let columns = result.schema.map(\.name)
        let rawTypeNames = result.schema.map(\.typeName)
        let columnTypeNames = rawTypeNames.map { R2SQLTypeMapper.displayTypeName(rawTypeName: $0) }

        let rows = result.rows.map { row in
            zip(columns, rawTypeNames).map { name, rawTypeName in
                R2SQLTypeMapper.value(for: row[name], rawTypeName: rawTypeName)
            }
        }

        return R2SQLResultSet(columns: columns, columnTypeNames: columnTypeNames, rows: rows)
    }

    public static func firstColumnStrings(_ result: R2SQLResult) -> [String] {
        let mapped = map(result)
        guard !mapped.columns.isEmpty else { return [] }
        return mapped.rows.compactMap { row in
            guard let first = row.first, case .text(let value) = first else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
