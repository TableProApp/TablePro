//
//  DatabaseTreeMenuSpec+Creation.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct SidebarCreationFacts: Equatable {
    internal var canCreateTable = false
    internal var canCreateView = false
    internal var supportsCreateSchema = false
    internal var supportsCreateDatabase = false
    internal var offersBrowsedFolders = false
    internal var schemaEntityName = "Schema"
    internal var activeDatabase: String?
}

internal extension SidebarCreationFacts {
    @MainActor
    static func resolve(
        connectionId: UUID,
        databaseType: DatabaseType,
        offersBrowsedFolders: Bool,
        activeDatabase: String?
    ) -> SidebarCreationFacts {
        let driver = DatabaseManager.shared.driver(for: connectionId)
        let plugins = PluginManager.shared
        return SidebarCreationFacts(
            canCreateTable: CreateTableEligibility.canCreateTable(with: driver),
            canCreateView: CreateViewEligibility.canCreateView(with: driver),
            supportsCreateSchema: plugins.supportsCreateSchema(for: databaseType),
            supportsCreateDatabase: plugins.supportsContainerSwitching(for: databaseType),
            offersBrowsedFolders: offersBrowsedFolders,
            schemaEntityName: plugins.schemaEntityName(for: databaseType),
            activeDatabase: activeDatabase
        )
    }

    // Asked on every sidebar redraw, so the driver probes run last and only when nothing cheaper answers.
    @MainActor
    static func offersAnyCreation(
        connectionId: UUID,
        databaseType: DatabaseType,
        offersBrowsedFolders: Bool
    ) -> Bool {
        if offersBrowsedFolders { return true }
        let plugins = PluginManager.shared
        if plugins.supportsCreateSchema(for: databaseType) || plugins.supportsContainerSwitching(for: databaseType) {
            return true
        }
        let driver = DatabaseManager.shared.driver(for: connectionId)
        return CreateViewEligibility.canCreateView(with: driver) || CreateTableEligibility.canCreateTable(with: driver)
    }
}

internal extension DatabaseTreeMenuSpec {
    /// The add button lists what read-only blocks so validation can dim it; the empty-area menu
    /// passes `hidesDatabaseWrites` and leaves it out. Folders are local, so read-only keeps them.
    static func creationSections(
        _ facts: SidebarCreationFacts,
        hidesDatabaseWrites: Bool
    ) -> [DatabaseTreeMenuSection] {
        let writes = !hidesDatabaseWrites
        var objects: [DatabaseTreeMenuItem] = []
        if writes, facts.canCreateTable {
            objects.append(.command(String(localized: "New Table…"), .createTable))
        }
        if writes, facts.canCreateView {
            objects.append(.command(String(localized: "New View…"), .createView))
        }
        var containers: [DatabaseTreeMenuItem] = []
        if writes, facts.supportsCreateSchema {
            containers.append(.command(
                String(format: String(localized: "New %@…"), facts.schemaEntityName),
                .createSchema(database: facts.activeDatabase)
            ))
        }
        if writes, facts.supportsCreateDatabase {
            containers.append(.command(String(localized: "New Database…"), .createDatabase))
        }
        var folders: [DatabaseTreeMenuItem] = []
        if facts.offersBrowsedFolders {
            folders.append(.command(String(localized: "New Folder"), .tableFolder(.create(.browsed))))
        }
        return [
            DatabaseTreeMenuSection(objects),
            DatabaseTreeMenuSection(containers),
            DatabaseTreeMenuSection(folders)
        ]
    }
}
