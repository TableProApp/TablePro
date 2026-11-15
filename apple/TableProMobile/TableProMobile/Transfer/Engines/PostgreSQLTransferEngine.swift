import Foundation
import os
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProPostgreSQLCore
import TableProSQLGrammar
import TableProSQLQuoting

// A driver that takes the rows of a script's `COPY ... FROM STDIN`, handed over a piece at a time.
nonisolated protocol CopyFromStandardInputDriving: DatabaseDriver {
    func copyFromStandardInput(statement: String, rows: PluginCopyData) async throws -> QueryResult
}

nonisolated extension PostgreSQLDriver: CatalogQuerying, ExportRowStreaming, CopyFromStandardInputDriving,
    MobileTransferEngine {
    private static let transferLogger = Logger(subsystem: "com.TablePro", category: "PostgreSQLTransfer")

    func catalogQuery(_ sql: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await catalogCells(sql, parameters: parameters)
    }

    func makeExportCatalog(context: MobileTransferContext) async throws -> any MobileExportCatalog {
        let script = ExportCatalogScript(databaseTypeId: databaseType.rawValue, session: settledLexicalFacts)
        let standardConformingStrings = !(settledLexicalFacts?.enabled.contains(.backslashEscapesInSingleQuotes) ?? false)
        guard databaseType != .redshift else {
            let read: RedshiftCatalogExport.Read = { [self] statement in try await catalogCells(statement).rows }
            return RedshiftMobileExportCatalog(
                catalog: RedshiftCatalogExport(
                    read: read,
                    currentSchema: effectiveSchema,
                    database: connectedDatabase,
                    serverVersionNumber: serverVersionNumber,
                    externalSchemas: try await Self.externalSchemas(read: read)
                ),
                script: script,
                standardConformingStrings: standardConformingStrings
            )
        }
        let catalog = PostgreSQLCatalogExport(
            read: { [self] statement, schema in try await catalogCells(statement, namesRelativeTo: schema).rows },
            currentSchema: effectiveSchema,
            capabilities: PostgreSQLCapabilities(serverVersion: serverVersionNumber),
            catalogCapabilities: .assumingModernWhenUnknown(serverVersionNumber),
            catalogPresence: catalogPresence
        )
        let sessionScope = PostgreSQLSessionScope(
            setting: { [self] statement, requiresIdleSession in
                try await executeSessionSetting(
                    statement.sql, parameters: statement.parameters, requiresIdleSession: requiresIdleSession
                )
            },
            transactionState: { [self] in await sessionTransactionState().pluginSessionState }
        )
        return PostgreSQLMobileExportCatalog(
            catalog: catalog,
            sessionScope: sessionScope,
            script: script,
            standardConformingStrings: standardConformingStrings
        )
    }

    func makeWriteDialect(context: MobileTransferContext) async throws -> any MobileWriteDialect {
        PostgreSQLMobileWriteDialect(
            databaseTypeId: databaseType.rawValue,
            currentSchema: effectiveSchema,
            capabilities: PostgreSQLCapabilities(serverVersion: serverVersionNumber),
            buildsTables: databaseType != .redshift
        )
    }

    // A failed probe lists only the local tables of a schema, as on the Mac.
    private static func externalSchemas(read: @escaping RedshiftCatalogExport.Read) async throws -> Set<String> {
        do {
            return try await RedshiftCatalogExport.externalSchemaNames(read: read)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            transferLogger.warning("Could not read svv_external_schemas: \(error.localizedDescription, privacy: .private)")
            return []
        }
    }
}

// Placeholders, quoting and the CREATE TABLE writer the Mac's PostgreSQL driver uses. Redshift has no writer on the
// Mac, so a new table is refused there too.
nonisolated struct PostgreSQLMobileWriteDialect: MobileWriteDialect {
    let databaseTypeId: String
    let currentSchema: String
    let capabilities: PostgreSQLCapabilities
    let buildsTables: Bool

    func importStatements(table: String, schema: String?, columns: [ColumnInfo]) async throws -> SQLImportStatements {
        SQLImportStatements(
            databaseTypeId: databaseTypeId,
            qualifiedTableName: ImportTableNames.qualified(table, schema: schema) { SQLQuoting.identifier($0) },
            parameterStyle: .dollar,
            quoteIdentifier: { SQLQuoting.identifier($0) },
            columnTypeNames: ImportTableNames.columnTypeNames(columns)
        )
    }

    func createTableStatements(definition: PluginCreateTableDefinition, schema: String?) throws -> [String] {
        guard buildsTables else { throw ImportTableNames.noStatement }
        if let reason = PostgreSQLVersionedStatements.refusal(for: definition, capabilities: capabilities) {
            throw MobileTransferRefusal(reason: reason)
        }
        guard let statements = PostgreSQLCreateTableSQL.statements(
            definition, schema: schema?.nilIfEmpty ?? currentSchema, capabilities: capabilities
        ) else {
            throw ImportTableNames.noStatement
        }
        return statements
    }
}
