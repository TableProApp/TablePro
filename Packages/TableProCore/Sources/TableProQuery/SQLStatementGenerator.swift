import Foundation

public struct SQLStatementGenerator: Sendable {
    private let dialect: QueryDialectDescriptor

    public init(dialect: QueryDialectDescriptor) {
        self.dialect = dialect
    }

    public func generateInsert(table: String, columns: [String], values: [String?]) -> String {
        let quotedTable = quoteIdentifier(table)
        let quotedColumns = columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let formattedValues = values.map { formatValue($0) }.joined(separator: ", ")
        return "INSERT INTO \(quotedTable) (\(quotedColumns)) VALUES (\(formattedValues))"
    }

    public func generateUpdate(
        table: String,
        changes: [String: String?],
        where whereConditions: [String: String]
    ) -> String {
        let quotedTable = quoteIdentifier(table)

        let setClauses = changes.map { key, value in
            "\(quoteIdentifier(key)) = \(formatValue(value))"
        }.joined(separator: ", ")

        let whereClauses = whereConditions.map { key, value in
            "\(quoteIdentifier(key)) = \(formatWhereValue(value))"
        }.joined(separator: " AND ")

        return "UPDATE \(quotedTable) SET \(setClauses) WHERE \(whereClauses)"
    }

    public func generateDelete(table: String, where whereConditions: [String: String]) -> String {
        let quotedTable = quoteIdentifier(table)

        let whereClauses = whereConditions.map { key, value in
            "\(quoteIdentifier(key)) = \(formatWhereValue(value))"
        }.joined(separator: " AND ")

        return "DELETE FROM \(quotedTable) WHERE \(whereClauses)"
    }

    private func quoteIdentifier(_ name: String) -> String {
        dialect.quoteIdentifier(name)
    }

    private func formatValue(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return dialect.sqlLiteral(
            for: value,
            trimWhitespace: false,
            interpretSpecialLiterals: false
        )
    }

    private func formatWhereValue(_ value: String) -> String {
        formatValue(value)
    }
}
