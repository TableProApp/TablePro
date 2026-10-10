//
//  SidebarSchemaFilter.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Every reader of one database's all-schema listing asks with this selection, or two readers flip
/// the held listing between their selections on each change.
@MainActor
internal struct SidebarSchemaFilter {
    private let databaseManager: DatabaseManager
    private let treeMetadata: DatabaseTreeMetadataService
    private let schemaService: SchemaService
    private let pluginManager: PluginManager

    internal init(
        databaseManager: DatabaseManager = .shared,
        treeMetadata: DatabaseTreeMetadataService = .shared,
        schemaService: SchemaService = .shared,
        pluginManager: PluginManager = .shared
    ) {
        self.databaseManager = databaseManager
        self.treeMetadata = treeMetadata
        self.schemaService = schemaService
        self.pluginManager = pluginManager
    }

    /// Nil means no filter. The browsed schema joins the kept set for the browsed database only,
    /// because it is a schema of that database alone.
    internal func keptSchemas(connectionId: UUID, database: String) -> Set<String>? {
        guard let session = databaseManager.session(for: connectionId) else { return nil }
        let type = session.connection.type
        guard DatabaseTreeMetadataService.listsTablesPerSchema(pluginManager.databaseGroupingStrategy(for: type))
        else { return nil }
        let selected = SharedSidebarState.forConnection(connectionId).schemaFilter(for: database)
        guard !selected.isEmpty else { return nil }
        let browse = databaseManager.browseScope(for: connectionId)
        return DatabaseTreeVisibility.keptSchemas(
            selected: selected,
            schemas: schemaList(connectionId: connectionId, database: database),
            systemSchemas: Set(pluginManager.systemSchemaNames(for: type)),
            showsSystem: AppSettingsManager.shared.general.showSystemContainers,
            activeSchema: browse?.database == database ? browse?.schema : nil
        )
    }

    internal func selection(connectionId: UUID, database: String) -> CatalogTableListing.SchemaSelection {
        guard let kept = keptSchemas(connectionId: connectionId, database: database) else { return .all }
        return .only(kept)
    }

    /// The schema names the connection has listed for the database, or nil while none are known.
    /// The tree's list answers first; the schema service holds the browsed database's, read at connect.
    internal func schemaList(connectionId: UUID, database: String) -> [String]? {
        if let listed = treeMetadata.schemaListState(connectionId: connectionId, database: database).value {
            return listed
        }
        guard schemaService.loadedScope(for: connectionId)?.database == database else { return nil }
        let schemas = schemaService.schemas(for: connectionId)
        return schemas.isEmpty ? nil : schemas
    }
}
