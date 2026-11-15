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

    // Every object of the database, each with the plugin's own defaults for its option columns.
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
            let exportCatalog = try await catalog(
                on: lease.driver, databaseType: databaseType, database: database, schema: schema
            )
            let objects = try await exportCatalog.exportObjects(database: database ?? "", schema: schema)
            await lease.close()
            let supported = Set(type(of: plugin).supportedObjectKinds)
            let defaults = plugin.defaultTableOptionValues()
            return objects.filter { supported.contains($0.kind) }.map { $0.withOptionValues(defaults) }
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
