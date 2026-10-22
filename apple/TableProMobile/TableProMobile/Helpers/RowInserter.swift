import Foundation
import TableProDatabase
import TableProModels

nonisolated enum RowInsertPlanner {
    // The defaults suit a Shortcuts payload, which cannot say "leave this column out" except by leaving it empty.
    static func statements(
        table: String,
        schema: String?,
        type: DatabaseType,
        driver: any DatabaseDriver,
        columns: [ColumnInfo],
        rows: [PayloadRow],
        allowAllDefaults: Bool = false,
        dropsEmptyPrimaryKey: Bool = true
    ) throws -> [String] {
        try insertValues(
            table: table, columns: columns, rows: rows,
            allowAllDefaults: allowAllDefaults, dropsEmptyPrimaryKey: dropsEmptyPrimaryKey
        ).compactMap { values in
            SQLBuilder.buildInsert(
                table: table,
                schema: schema,
                type: type,
                driver: driver,
                columns: values.map(\.column),
                values: values.map(\.value)
            )
        }
    }

    static func batch(
        table: String,
        schema: String?,
        type: DatabaseType,
        driver: any DatabaseDriver,
        columns: [ColumnInfo],
        rows: [PayloadRow],
        allowAllDefaults: Bool = false,
        dropsEmptyPrimaryKey: Bool = true
    ) throws -> RowWriteBatch? {
        guard let writer = driver as? any DriverRowWriting else {
            let sql = try statements(
                table: table, schema: schema, type: type, driver: driver, columns: columns, rows: rows,
                allowAllDefaults: allowAllDefaults, dropsEmptyPrimaryKey: dropsEmptyPrimaryKey
            )
            return sql.isEmpty ? nil : .sql(sql, driver)
        }
        let writes = try insertValues(
            table: table, columns: columns, rows: rows,
            allowAllDefaults: allowAllDefaults, dropsEmptyPrimaryKey: dropsEmptyPrimaryKey
        ).flatMap { values in
            try writer.insertWrites(table: table, schema: schema, columns: columns.map(\.name), values: values)
        }
        return writes.isEmpty ? nil : .driver(writes, writer)
    }

    private static func insertValues(
        table: String,
        columns: [ColumnInfo],
        rows: [PayloadRow],
        allowAllDefaults: Bool,
        dropsEmptyPrimaryKey: Bool
    ) throws -> [[(column: String, value: String?)]] {
        try PayloadRowPlanner.values(
            table: table,
            columns: columns.map {
                PayloadColumn(name: $0.name, isPrimaryKey: $0.isPrimaryKey, isServerOwned: $0.isServerOwned)
            },
            rows: rows,
            allowAllDefaults: allowAllDefaults,
            dropsEmptyPrimaryKey: dropsEmptyPrimaryKey
        )
    }
}

nonisolated enum RowInserter {
    static func insert(
        driver: any DatabaseDriver,
        table: String,
        type: DatabaseType,
        schema: String?,
        qualifier: String?,
        rows: [PayloadRow]
    ) async throws -> Int {
        let columns = try await driver.fetchColumns(table: table, schema: schema)
        guard let batch = try RowInsertPlanner.batch(
            table: table,
            schema: qualifier,
            type: type,
            driver: driver,
            columns: columns,
            rows: rows
        ) else { throw IntentDataError.noInsertableValues(table) }

        // The write joins an autocommit-off transaction, and this session closes right after, which would roll it back.
        guard await driver.sessionTransactionState() == .implicitTransaction else {
            return try await batch.run()
        }
        do {
            let affected = try await batch.run()
            try await driver.commitTransaction()
            return affected
        } catch {
            try? await driver.rollbackTransaction()
            throw error
        }
    }
}
