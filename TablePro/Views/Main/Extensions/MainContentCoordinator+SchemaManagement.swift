//
//  MainContentCoordinator+SchemaManagement.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    /// Whether this connection's engine makes schemas, and the connection is not read-only.
    var schemaEditContext: SchemaEditEligibility.Context {
        SchemaEditEligibility.Context(
            supportsCreateSchema: services.pluginManager.supportsCreateSchema(for: connection.type),
            supportsSchemaOwner: services.pluginManager.supportsSchemaOwner(for: connection.type),
            supportsSchemaPrivileges: services.pluginManager.supportsSchemaPrivileges(for: connection.type),
            supportsRenameSchema: services.pluginManager.supportsRenameSchema(for: connection.type),
            isReadOnly: safeModeLevel.blocksAllWrites
        )
    }

    func createSchema(database: String?) {
        guard SchemaEditEligibility.canCreate(context: schemaEditContext) else { return }
        activeSheet = .createSchema(database: database?.nilIfEmpty ?? browseDatabaseName)
    }

    func editSchema(_ container: DatabaseContainerRef) {
        guard SchemaEditEligibility.editable([container], context: schemaEditContext) != nil else { return }
        activeSheet = .editSchema(container)
    }

    /// Selects the schema the user just created, which is the point of creating it. Only when the
    /// sheet was opened on the database the window is browsing: switching the window to another
    /// database because a schema was made there is not what the user asked for.
    func switchSchemaAfterCreate(in database: String?, to schema: String) async {
        guard !schema.isEmpty, isBrowsing(database) else { return }
        await switchContainers(database: nil, schema: schema)
    }

    /// Keeps the window pointed at the schema the user just edited, under whatever name it now has.
    /// A rename is adopted the same way the sidebar's inline rename adopts one, so open tabs, the
    /// browse cursor and Recents all follow it rather than pointing at a name that is gone.
    ///
    /// The database has to match as well as the name. Comparing the schema alone switched a window
    /// browsing `public` in one database to the new name of a same-named schema renamed in another,
    /// and PostgreSQL accepts a search path naming nothing, so the window was left with no current
    /// schema at all.
    func adoptSchemaEdit(_ container: DatabaseContainerRef, renamedTo newName: String) async {
        guard let oldName = container.schema, !newName.isEmpty, oldName != newName else { return }
        services.catalogChangeService.record(
            .containerRenamed(container, to: newName, connectionId: connection.id)
        )
        guard isBrowsing(container.database) else { return }
        let liveSchema = DatabaseManager.shared.session(for: connection.id)?.browseSchema
        guard (toolbarState.currentSchema ?? liveSchema) == oldName else { return }
        await switchContainers(database: nil, schema: newName)
    }

    /// Whether the window is on the database the sheet acted in. A nil database means the sheet was
    /// opened without one, which only happens from the switcher on the browsed database.
    private func isBrowsing(_ database: String?) -> Bool {
        guard let database, !database.isEmpty else { return true }
        return database == browseDatabaseName
    }
}
