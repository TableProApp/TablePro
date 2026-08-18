//
//  ExportModels.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// MARK: - Export Mode

/// What the export dialog starts with selected: named tables inside the current
/// container, or every table of whole databases or schemas.
enum ExportPreselection: Equatable {
    case tables(Set<String>)
    case containers([DatabaseContainerRef])

    /// `container` is the ref the dialog is listing, not its bare name. Matching on the name alone
    /// compared a database name against schema names, so a preselected database selected nothing on
    /// a schema-grouped engine and quietly matched an unrelated schema that happened to share a name.
    func selects(table: String, inContainer container: DatabaseContainerRef, isCurrentContainer: Bool) -> Bool {
        switch self {
        case .tables(let names):
            return isCurrentContainer && names.contains(table)
        case .containers(let refs):
            return refs.contains { $0.covers(container) }
        }
    }

    var singleTableName: String? {
        guard case .tables(let names) = self, names.count == 1 else { return nil }
        return names.first
    }

    var containerNames: [String] {
        guard case .containers(let refs) = self else { return [] }
        return refs.map(\.name)
    }

    /// The one database this preselection is about, when every ref agrees on it. The export dialog
    /// scopes itself to that database, so exporting a database other than the active one lists and
    /// exports that database rather than the one the sidebar happens to be browsing.
    var scopedDatabase: String? {
        guard case .containers(let refs) = self, let first = refs.first else { return nil }
        guard refs.allSatisfy({ $0.database == first.database }) else { return nil }
        return first.database
    }

    /// The dialog can open a second connection to any database on the server, so a container in
    /// another database is preselectable. It cannot on an engine whose database lives inside the
    /// driver instance rather than on a server it reconnects to, which is what
    /// `canReachOtherDatabases` reports; there, only the active database has anything to list.
    static func canPreselect(
        containers: [DatabaseContainerRef],
        activeDatabase: String?,
        canReachOtherDatabases: Bool
    ) -> Bool {
        guard !containers.isEmpty else { return false }
        guard containers.allSatisfy({ $0.database == containers[0].database }) else { return false }
        guard !canReachOtherDatabases else { return true }
        return containers.allSatisfy { $0.database == activeDatabase }
    }
}

/// Defines the export mode: either exporting database tables or in-memory query results.
enum ExportMode {
    case tables(connection: DatabaseConnection, preselection: ExportPreselection)
    case queryResults(connection: DatabaseConnection, tableRows: TableRows, suggestedFileName: String)
    case streamingQuery(connection: DatabaseConnection, query: String, suggestedFileName: String)
}

// MARK: - Export Configuration

@MainActor
struct ExportConfiguration {
    var formatId: String = "csv"
    var fileName: String = "export"

    var fullFileName: String {
        guard let plugin = PluginManager.shared.exportPlugin(forFormat: formatId) else {
            return "\(fileName).\(formatId)"
        }
        return "\(fileName).\(plugin.currentFileExtension)"
    }

    var fileExtension: String {
        guard let plugin = PluginManager.shared.exportPlugin(forFormat: formatId) else {
            return formatId
        }
        return plugin.currentFileExtension
    }
}

// MARK: - Tree View Models

struct ExportTableItem: Identifiable, Hashable {
    let id: UUID
    let name: String
    let databaseName: String
    let type: TableInfo.TableType
    var isSelected: Bool = false
    var optionValues: [Bool] = []

    init(
        id: UUID = UUID(),
        name: String,
        databaseName: String = "",
        type: TableInfo.TableType,
        isSelected: Bool = false,
        optionValues: [Bool] = []
    ) {
        self.id = id
        self.name = name
        self.databaseName = databaseName
        self.type = type
        self.isSelected = isSelected
        self.optionValues = optionValues
    }

    var qualifiedName: String {
        databaseName.isEmpty ? name : "\(databaseName).\(name)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ExportTableItem, rhs: ExportTableItem) -> Bool {
        lhs.id == rhs.id
    }
}

struct ExportDatabaseItem: Identifiable {
    let id: UUID
    let name: String
    var tables: [ExportTableItem]
    var isExpanded: Bool = true

    init(
        id: UUID = UUID(),
        name: String,
        tables: [ExportTableItem],
        isExpanded: Bool = true
    ) {
        self.id = id
        self.name = name
        self.tables = tables
        self.isExpanded = isExpanded
    }

    var selectedCount: Int {
        tables.count(where: \.isSelected)
    }

    var allSelected: Bool {
        !tables.isEmpty && tables.allSatisfy { $0.isSelected }
    }

    var noneSelected: Bool {
        tables.allSatisfy { !$0.isSelected }
    }

    var selectedTables: [ExportTableItem] {
        tables.filter { $0.isSelected }
    }
}

extension ExportTableItem {
    func normalized(forOptionColumnCount optionColumnCount: Int, defaultOptionValues: [Bool]) -> ExportTableItem {
        guard optionColumnCount > 0 else { return self }
        let fallback = defaultOptionValues.count == optionColumnCount
            ? defaultOptionValues
            : Array(repeating: true, count: optionColumnCount)
        var normalizedItem = self
        if normalizedItem.optionValues.count != optionColumnCount {
            normalizedItem.optionValues = fallback
        }
        if normalizedItem.isSelected, !normalizedItem.optionValues.contains(true) {
            normalizedItem.optionValues = fallback
        }
        return normalizedItem
    }
}

extension [ExportDatabaseItem] {
    func normalizingOptionValues(optionColumnCount: Int, defaultOptionValues: [Bool]) -> [ExportDatabaseItem] {
        map { database in
            var normalizedDatabase = database
            normalizedDatabase.tables = database.tables.map {
                $0.normalized(forOptionColumnCount: optionColumnCount, defaultOptionValues: defaultOptionValues)
            }
            return normalizedDatabase
        }
    }

    func resettingOptionValues(to values: [Bool]) -> [ExportDatabaseItem] {
        map { database in
            var resetDatabase = database
            resetDatabase.tables = database.tables.map { table in
                var resetTable = table
                resetTable.optionValues = values
                return resetTable
            }
            return resetDatabase
        }
    }
}
