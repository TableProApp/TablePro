import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit

nonisolated enum RowWriteBatch: Sendable {
    case sql([String], any DatabaseDriver)
    case driver([PluginRowWrite], any DriverRowWriting)

    var isEmpty: Bool {
        switch self {
        case .sql(let statements, _): statements.isEmpty
        case .driver(let writes, _): writes.isEmpty
        }
    }

    var statements: [String] {
        switch self {
        case .sql(let statements, _): statements
        case .driver(let writes, _): writes.map(\.statement)
        }
    }

    @discardableResult
    func run() async throws -> Int {
        switch self {
        case .sql(let statements, let driver): try await driver.executeWrite(statements)
        case .driver(let writes, let writer): try await writer.run(writes)
        }
    }

    static func update(
        table: String,
        schema: String?,
        type: DatabaseType,
        driver: any DatabaseDriver,
        columns: [String],
        locator: RowLocator,
        changes: [(column: String, value: String?)]
    ) throws -> RowWriteBatch? {
        guard !changes.isEmpty else { return nil }
        if let writer = driver as? any DriverRowWriting {
            let writes = try writer.updateWrites(
                table: table, schema: schema, columns: columns, originalRow: locator.row, changes: changes
            )
            return .driver(writes, writer)
        }
        guard let keys = locator.keyValues else { return nil }
        let sql = SQLBuilder.buildUpdate(
            table: table, schema: schema, type: type, driver: driver, changes: changes, primaryKeys: keys
        )
        return .sql([sql], driver)
    }

    static func delete(
        table: String,
        schema: String?,
        type: DatabaseType,
        driver: any DatabaseDriver,
        columns: [String],
        locator: RowLocator
    ) throws -> RowWriteBatch? {
        if let writer = driver as? any DriverRowWriting {
            let writes = try writer.deleteWrites(table: table, schema: schema, columns: columns, originalRow: locator.row)
            return .driver(writes, writer)
        }
        guard let keys = locator.keyValues, !keys.isEmpty else { return nil }
        let sql = SQLBuilder.buildDelete(table: table, schema: schema, type: type, driver: driver, primaryKeys: keys)
        return .sql([sql], driver)
    }
}
