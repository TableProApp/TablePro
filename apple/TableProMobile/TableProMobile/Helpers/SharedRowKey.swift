import Foundation
import TableProDatabase
import TableProModels

// A SQLite column with no type can hold the number 5 and the text '5' as two keys that both read as 5.
nonisolated enum SharedRowKey {
    // A row matched on every value it holds is not one row when another holds the same values: ClickHouse would
    // change both. An update that matches none would report success and drop the typed values.
    static func identicalRowsError(
        writer: any DriverRowWriting,
        table: String,
        schema: String?,
        locator: RowLocator,
        columns: [String],
        type: DatabaseType,
        isUpdate: Bool
    ) async -> AppError? {
        guard locator.keyValues == nil else { return nil }
        let count: Int
        do {
            count = try await writer.matchingRowCount(table: table, schema: schema, columns: columns, row: locator.row)
        } catch {
            return ErrorClassifier.classify(error, context: ErrorContext(operation: "checkRowKey", databaseType: type))
        }
        if count == 0, isUpdate {
            return AppError(
                category: .query,
                title: String(localized: "Row Not Found"),
                message: CellLookupError.rowNotFound.localizedDescription,
                recovery: String(localized: "Reload the table to see the row as it is now."),
                underlying: CellLookupError.rowNotFound
            )
        }
        guard count > 1 else { return nil }
        return AppError(
            category: .query,
            title: String(localized: "Identical Rows"),
            message: String(localized: "Another row holds the same value in every column, so this row cannot be changed on its own. Change these rows with a query."),
            recovery: nil,
            underlying: nil
        )
    }

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
