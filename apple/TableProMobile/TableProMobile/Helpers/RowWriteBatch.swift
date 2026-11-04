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
        columnDetails: [ColumnInfo],
        locator: RowLocator,
        changes: [(column: String, value: String?)]
    ) throws -> RowWriteBatch? {
        guard !changes.isEmpty else { return nil }
        if let writer = driver as? any DriverRowWriting {
            let writes = try writer.updateWrites(
                table: table, schema: schema, columns: columns, originalRow: locator.row,
                documentLocator: locator.documentLocator, changes: changes
            )
            return .driver(writes, writer)
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
            let writes = try writer.deleteWrites(
                table: table, schema: schema, columns: columns, originalRow: locator.row,
                documentLocator: locator.documentLocator
            )
            return .driver(writes, writer)
        }
        guard let keys = locator.keyValues, !keys.isEmpty else { return nil }
        let sql = SQLBuilder.buildDelete(
            table: table, schema: schema, type: type, driver: driver, primaryKeys: keys, columns: columnDetails
        )
        return .sql([sql], driver)
    }
}

// Escaping is a session fact (MySQL's NO_BACKSLASH_ESCAPES), which a redial can reset, so a write keeps its inputs and
// is built on the driver that runs it: SQL text built for one session never runs on another.
nonisolated struct PlannedRowWrite: Sendable {
    private let build: @Sendable (any DatabaseDriver) throws -> RowWriteBatch?

    init(_ build: @escaping @Sendable (any DatabaseDriver) throws -> RowWriteBatch?) {
        self.build = build
    }

    func batch(on driver: any DatabaseDriver) throws -> RowWriteBatch? {
        try build(driver)
    }

    static func update(
        table: String,
        schema: String?,
        type: DatabaseType,
        columns: [String],
        columnDetails: [ColumnInfo],
        locator: RowLocator,
        changes: [(column: String, value: String?)]
    ) -> PlannedRowWrite {
        PlannedRowWrite { driver in
            try RowWriteBatch.update(
                table: table, schema: schema, type: type, driver: driver, columns: columns,
                columnDetails: columnDetails, locator: locator, changes: changes
            )
        }
    }

    static func insert(
        table: String,
        schema: String?,
        type: DatabaseType,
        columns: [ColumnInfo],
        values: [String: PayloadValue]
    ) -> PlannedRowWrite {
        PlannedRowWrite { driver in
            try RowInsertPlanner.batch(
                table: table, schema: schema, type: type, driver: driver, columns: columns,
                rows: [PayloadRow(values: values)], allowAllDefaults: true, dropsEmptyPrimaryKey: false
            )
        }
    }
}
