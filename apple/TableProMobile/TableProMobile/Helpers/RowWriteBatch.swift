import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit

nonisolated enum RowWriteBatch: Sendable {
    case sql([String], any DatabaseDriver)
    case driver([PluginRowWrite], any DriverRowWriting)
    case rowChange([PluginRowWrite], any DriverRowWriting, RowTarget)

    var isEmpty: Bool {
        switch self {
        case .sql(let statements, _): statements.isEmpty
        case .driver(let writes, _), .rowChange(let writes, _, _): writes.isEmpty
        }
    }

    var statements: [String] {
        switch self {
        case .sql(let statements, _): statements
        case .driver(let writes, _), .rowChange(let writes, _, _): writes.map(\.statement)
        }
    }

    @discardableResult
    func run() async throws -> Int {
        switch self {
        case .sql(let statements, let driver): try await driver.executeWrite(statements)
        case .driver(let writes, let writer): try await writer.run(writes)
        case .rowChange(let writes, let writer, let target): try await writer.run(writes, changing: target)
        }
    }

    static func update(
        table: String,
        schema: String?,
        type: DatabaseType,
        driver: any DatabaseDriver,
        columns: [String],
        columnDetails: [ColumnInfo],
        locator: RowLocator,
        changes: [(column: String, value: String?)]
    ) throws -> RowWriteBatch? {
        guard !changes.isEmpty else { return nil }
        if let writer = driver as? any DriverRowWriting {
            let writes = try writer.updateWrites(
                table: table, schema: schema, columns: columns, originalRow: locator.row, changes: changes
            )
            var changed = locator.row
            for change in changes {
                guard let index = columns.firstIndex(of: change.column), index < changed.count else { continue }
                changed[index] = change.value
            }
            return .rowChange(writes, writer, RowTarget(table: table, columns: columns, row: locator.row, changedRow: changed))
        }
        guard let keys = locator.keyValues else { return nil }
        let sql = SQLBuilder.buildUpdate(
            table: table, schema: schema, type: type, driver: driver, changes: changes, primaryKeys: keys,
            columns: columnDetails
        )
        return .sql([sql], driver)
    }

    static func delete(
        table: String,
        schema: String?,
        type: DatabaseType,
        driver: any DatabaseDriver,
        columns: [String],
        columnDetails: [ColumnInfo],
        locator: RowLocator
    ) throws -> RowWriteBatch? {
        if let writer = driver as? any DriverRowWriting {
            let writes = try writer.deleteWrites(table: table, schema: schema, columns: columns, originalRow: locator.row)
            return .rowChange(writes, writer, RowTarget(table: table, columns: columns, row: locator.row, changedRow: nil))
        }
        guard let keys = locator.keyValues, !keys.isEmpty else { return nil }
        let sql = SQLBuilder.buildDelete(
            table: table, schema: schema, type: type, driver: driver, primaryKeys: keys, columns: columnDetails
        )
        return .sql([sql], driver)
    }
}
