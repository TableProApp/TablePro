//
//  DriverBackedSchemaProvider.swift
//  TableProTests
//
//  A production provider reads columns through its scope's lease and takes its table list from
//  whoever read it. These build the same shape over one test driver.
//

import Foundation
@testable import TablePro

extension SQLSchemaProvider {
    /// Reads columns, all columns and foreign keys from `driver`, as a provider the registry builds
    /// reads them through its scope's lease.
    static func reading(from driver: DatabaseDriver) -> SQLSchemaProvider {
        SQLSchemaProvider(metadataSource: ColumnMetadataSource(
            fetchColumns: { table, schema in try await driver.fetchColumns(table: table, schema: schema) },
            fetchAllColumns: { try await driver.fetchAllColumns(schema: nil) },
            fetchForeignKeys: { table, schema in
                guard driver.connection.type.supportsForeignKeys else { return [] }
                return try await driver.fetchForeignKeys(table: table, schema: schema)
            }
        ))
    }

    func resetForDatabase(
        _ database: String?,
        tables: [TableInfo],
        driver: DatabaseDriver,
        connection: DatabaseConnection? = nil
    ) {
        resetForDatabase(database, tables: tables, facts: CatalogDriverFacts(driver), connection: connection)
    }

    /// Reads the table list from `driver` and pushes it in, as the schema service does after a load.
    func loadSchema(using driver: DatabaseDriver, connection: DatabaseConnection? = nil) async {
        let tables = (try? await driver.fetchTables(schema: nil)) ?? []
        resetForDatabase(nil, tables: tables, facts: CatalogDriverFacts(driver), connection: connection)
    }
}
