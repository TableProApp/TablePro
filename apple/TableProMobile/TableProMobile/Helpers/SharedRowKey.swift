import Foundation
import TableProDatabase
import TableProModels

// A SQLite column with no type can hold the number 5 and the text '5' as two keys that both read as 5.
nonisolated enum SharedRowKey {
    static func error(
        table: String,
        schema: String?,
        key: [(column: String, value: String)],
        columns: [ColumnInfo],
        type: DatabaseType,
        driver: any DatabaseDriver
    ) async -> AppError? {
        guard SQLBuilder.keyMatchesEitherWay(key, columns: columns, type: type) else { return nil }
        let query = SQLBuilder.buildKeyMatchCount(
            table: table, schema: schema, key: key, columns: columns, type: type, driver: driver
        )
        let count: Int
        do {
            let result = try await driver.execute(query: query)
            count = result.rows.first?.first.flatMap { $0 }.flatMap { Int($0) } ?? 0
        } catch {
            return ErrorClassifier.classify(error, context: ErrorContext(operation: "checkRowKey", databaseType: type))
        }
        guard count > 1 else { return nil }
        return AppError(
            category: .query,
            title: String(localized: "Key Matches Several Rows"),
            message: String(localized: "More than one row reads as this key, because a SQLite column with no type keeps a number and the same text apart. Change these rows with a query."),
            recovery: nil,
            underlying: nil
        )
    }
}
