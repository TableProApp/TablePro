import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProRedisCore

// Rows only, for CSV, JSON, XLSX and Markdown: SQL and MQL leave Redis out, as on the Mac. No import.
nonisolated extension RedisDriver: MobileTransferEngine {
    func makeExportCatalog(context: MobileTransferContext) async throws -> any MobileExportCatalog {
        RedisTransferCatalog(driver: self)
    }

    // The list shows keys, but the export's objects are whole databases, as on the Mac: Export Database lists them.
    var exportsListedTables: Bool { false }
}

// Each database is one object, read whole with the Mac's `KEYBROWSE DB n` export statement, as the Mac's flat tree
// lists them.
nonisolated struct RedisTransferCatalog: MobileExportCatalog {
    let driver: RedisDriver

    var databaseTypeId: String { DatabaseType.redis.rawValue }

    func exportObjects(database: String, schema: String?) async throws -> [PluginExportTable] {
        try await driver.fetchDatabases().map { name in
            PluginExportTable(
                name: name, databaseName: "", tableType: PluginExportObjectKind.table.rawValue, schema: nil, kind: .table
            )
        }
    }

    func rowsQuery(for object: PluginExportTable) -> String? {
        RedisQueryBuilder().buildExportQuery(database: RedisDatabaseIndex.parse(object.name))
    }

    func quoteIdentifier(_ identifier: String) -> String {
        identifier
    }

    func escapeStringLiteral(_ value: String) -> String {
        driver.escapeStringLiteral(value)
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        throw PluginObjectSourceError.unsupported(table)
    }

    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] {
        [
            PluginColumnInfo(name: "Key", dataType: "String", isNullable: false, isPrimaryKey: true),
            PluginColumnInfo(name: "Type", dataType: "String", isNullable: true),
            PluginColumnInfo(name: "TTL", dataType: "Int64", isNullable: true),
            PluginColumnInfo(name: "Length", dataType: "Int64", isNullable: true, isGenerated: true),
            PluginColumnInfo(name: "Value", dataType: "String", isNullable: true),
        ]
    }
}
