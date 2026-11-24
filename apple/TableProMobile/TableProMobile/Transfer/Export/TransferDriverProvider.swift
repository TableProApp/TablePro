import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit

// The connection an export reads on. A long read on the window's session would end the moment the user browses, so
// the provider opens one of its own; an engine with one connection per file may hand back the session itself.
nonisolated struct TransferDriverLease: Sendable {
    let driver: any DatabaseDriver
    // The window's own session: its open transaction must not see a snapshot BEGIN or COMMIT, and it is never closed.
    let isSessionDriver: Bool
    let close: @Sendable () async -> Void
}

nonisolated extension TransferDriverLease {
    // A connection of the export's own opens on the connection's default schema. The schema the window shows is set on
    // it before anything reads, so an unqualified name reads the table the user sees; the session already reads there.
    // One that opened there already keeps the server's own search path.
    func settle(schema: String?) async throws {
        guard !isSessionDriver, let schema, !schema.isEmpty, driver.supportsSchemas, driver.currentSchema != schema
        else { return }
        do {
            try await driver.switchSchema(to: schema)
        } catch {
            throw MobileTransferRefusal(reason: String(
                format: String(localized: "Could not switch to schema %1$@: %2$@"), schema, error.localizedDescription
            ))
        }
    }
}

nonisolated protocol TransferDriverProvider: Sendable {
    func openTransferDriver() async throws -> TransferDriverLease
}

nonisolated struct DedicatedTransferDriverProvider: TransferDriverProvider {
    let connectionManager: ConnectionManager
    let connectionId: UUID
    let database: String?

    // The manager registered the driver, so its own close takes it back off the list a disconnect walks.
    func openTransferDriver() async throws -> TransferDriverLease {
        let driver = try await connectionManager.openDedicatedDriver(for: connectionId, database: database)
        let isSession = connectionManager.session(for: connectionId)?.driver === driver
        let manager = connectionManager
        let connectionId = connectionId
        return TransferDriverLease(driver: driver, isSessionDriver: isSession, close: {
            guard !isSession else { return }
            await manager.closeDedicatedDriver(driver, for: connectionId)
        })
    }
}

nonisolated enum ExportObjectListing {
    static func supportsExport(_ driver: any DatabaseDriver) -> Bool {
        driver is any MobileTransferEngine
    }

    // Whether a table the list shows is one object of the export, so its own Export entry has something to list.
    static func supportsTableExport(_ driver: any DatabaseDriver) -> Bool {
        (driver as? any MobileTransferEngine)?.exportsListedTables ?? false
    }

    static func catalog(
        on driver: any DatabaseDriver,
        databaseType: DatabaseType,
        database: String?,
        schema: String?
    ) async throws -> any MobileExportCatalog {
        guard let engine = driver as? any MobileTransferEngine else {
            throw MobileTransferRefusal(reason: String(
                format: String(localized: "%@ cannot export to a file."), databaseType.mobileDisplayName
            ))
        }
        return try await engine.makeExportCatalog(context: MobileTransferContext(
            databaseType: databaseType, database: database, schema: schema
        ))
    }

    // Every object of the database, whatever the format writes, so another format chosen later shows its own kinds.
    // Each object starts with the plugin's own defaults for its option columns.
    static func load(
        connectionManager: ConnectionManager,
        connectionId: UUID,
        databaseType: DatabaseType,
        database: String?,
        schema: String?,
        plugin: any ExportFormatPlugin
    ) async throws -> [PluginExportTable] {
        try await load(
            drivers: DedicatedTransferDriverProvider(
                connectionManager: connectionManager, connectionId: connectionId, database: database
            ),
            databaseType: databaseType, database: database, schema: schema, plugin: plugin
        )
    }

    static func load(
        drivers: any TransferDriverProvider,
        databaseType: DatabaseType,
        database: String?,
        schema: String?,
        plugin: any ExportFormatPlugin
    ) async throws -> [PluginExportTable] {
        let lease = try await drivers.openTransferDriver()
        do {
            try await lease.settle(schema: schema)
            let exportCatalog = try await catalog(
                on: lease.driver, databaseType: databaseType, database: database, schema: schema
            )
            let objects = try await exportCatalog.exportObjects(database: database ?? "", schema: schema)
            await lease.close()
            return objects.map { $0.withOptionValues(ExportObjectOptions.defaults(for: $0.kind, plugin: plugin)) }
        } catch {
            await lease.close()
            throw error
        }
    }
}

nonisolated extension PluginExportTable {
    func withOptionValues(_ values: [Bool]) -> PluginExportTable {
        PluginExportTable(
            name: name,
            databaseName: databaseName,
            tableType: tableType,
            optionValues: values,
            schema: schema,
            kind: kind,
            identity: identity,
            parentTable: parentTable,
            rowScope: rowScope
        )
    }

    func withRowScope(_ scope: PluginExportRowScope) -> PluginExportTable {
        PluginExportTable(
            name: name,
            databaseName: databaseName,
            tableType: tableType,
            optionValues: optionValues,
            schema: schema,
            kind: kind,
            identity: identity,
            parentTable: parentTable,
            rowScope: scope
        )
    }
}

// A format's default option values for one kind, with each column the kind does not take cleared.
nonisolated enum ExportObjectOptions {
    static func defaults(for kind: PluginExportObjectKind, plugin: any ExportFormatPlugin) -> [Bool] {
        let format = type(of: plugin)
        let columns = format.perTableOptionColumns
        return ExportOptionMask.masked(
            plugin.defaultTableOptionValues(), columns: columns, kind: kind, supports: format.supportsOption(columnId:for:)
        )
    }
}
