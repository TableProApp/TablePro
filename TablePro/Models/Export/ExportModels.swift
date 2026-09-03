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
    ///
    /// `kind` is what keeps a routine or trigger that shares a table's name out of a table
    /// preselection. Selecting a whole container still takes every kind in it.
    func selects(
        object: String,
        kind: PluginExportObjectKind,
        inContainer container: DatabaseContainerRef,
        isCurrentContainer: Bool
    ) -> Bool {
        switch self {
        case .tables(let names):
            guard kind == .table || kind == .view || kind == .materializedView || kind == .foreignTable else {
                return false
            }
            return isCurrentContainer && names.contains(object)
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

/// One selectable thing in the export tree: a table, a view, a routine, a trigger, a type or a
/// principal whose grants are being exported. `optionValues` stays positionally aligned with the
/// format's full `perTableOptionColumns` for every kind, so a column a kind does not support is a
/// blank slot rather than a shifted one.
struct ExportObjectItem: Identifiable, Hashable {
    let id: UUID
    let name: String
    let databaseName: String
    let kind: PluginExportObjectKind

    /// Whatever addresses this exact object again: a routine's argument signature, a principal's
    /// host part. Nil for a kind that a name alone identifies.
    let identity: String?

    /// The table a trigger fires for. Nil for every other kind.
    let parentTable: String?

    var isSelected: Bool = false
    var optionValues: [Bool] = []

    /// Which rows and columns of this object to write. Only a kind that carries rows can narrow.
    var rowScope: PluginExportRowScope = .unrestricted

    init(
        id: UUID = UUID(),
        name: String,
        databaseName: String = "",
        kind: PluginExportObjectKind,
        identity: String? = nil,
        parentTable: String? = nil,
        isSelected: Bool = false,
        optionValues: [Bool] = [],
        rowScope: PluginExportRowScope = .unrestricted
    ) {
        self.id = id
        self.name = name
        self.databaseName = databaseName
        self.kind = kind
        self.identity = identity
        self.parentTable = parentTable
        self.isSelected = isSelected
        self.optionValues = optionValues
        self.rowScope = rowScope
    }

    var qualifiedName: String {
        databaseName.isEmpty ? name : "\(databaseName).\(name)"
    }

    /// What the row shows after the name, so two overloads of one routine and two triggers of one
    /// table are told apart without opening anything.
    var subtitle: String? {
        switch kind {
        case .routine:
            guard let identity, !identity.isEmpty else { return nil }
            return identity
        case .trigger:
            guard let parentTable, !parentTable.isEmpty else { return nil }
            return parentTable
        case .grant:
            guard let identity, !identity.isEmpty else { return nil }
            return "@\(identity)"
        default:
            return nil
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ExportObjectItem, rhs: ExportObjectItem) -> Bool {
        lhs.id == rhs.id
    }
}

struct ExportDatabaseItem: Identifiable {
    let id: UUID
    let name: String
    var objects: [ExportObjectItem]
    var isExpanded: Bool = true

    init(
        id: UUID = UUID(),
        name: String,
        objects: [ExportObjectItem],
        isExpanded: Bool = true
    ) {
        self.id = id
        self.name = name
        self.objects = objects
        self.isExpanded = isExpanded
    }

    var selectedCount: Int {
        objects.count(where: \.isSelected)
    }

    var allSelected: Bool {
        !objects.isEmpty && objects.allSatisfy { $0.isSelected }
    }

    var noneSelected: Bool {
        objects.allSatisfy { !$0.isSelected }
    }

    var selectedObjects: [ExportObjectItem] {
        objects.filter { $0.isSelected }
    }

    /// The kinds present, in dump order, which is the order the groups appear in the tree.
    var presentKinds: [PluginExportObjectKind] {
        var seen: Set<PluginExportObjectKind> = []
        return objects
            .map(\.kind)
            .filter { seen.insert($0).inserted }
            .sorted { $0.dumpOrder < $1.dumpOrder }
    }

    func objects(ofKind kind: PluginExportObjectKind) -> [ExportObjectItem] {
        objects.filter { $0.kind == kind }
    }
}

extension ExportObjectItem {
    func normalized(forOptionColumnCount optionColumnCount: Int, defaultOptionValues: [Bool]) -> ExportObjectItem {
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

    /// Clears every option the format says this kind does not support, so a routine never carries a
    /// `Data` flag that would make it look exportable for a phase it has no rows for.
    func maskingUnsupportedOptions(
        columns: [PluginExportOptionColumn],
        supports: (String, PluginExportObjectKind) -> Bool
    ) -> ExportObjectItem {
        guard optionValues.count == columns.count else { return self }
        var masked = self
        masked.optionValues = zip(columns, optionValues).map { column, value in
            supports(column.id, kind) ? value : false
        }
        return masked
    }
}

extension [ExportDatabaseItem] {
    func normalizingOptionValues(optionColumnCount: Int, defaultOptionValues: [Bool]) -> [ExportDatabaseItem] {
        map { database in
            var normalizedDatabase = database
            normalizedDatabase.objects = database.objects.map {
                $0.normalized(forOptionColumnCount: optionColumnCount, defaultOptionValues: defaultOptionValues)
            }
            return normalizedDatabase
        }
    }

    func resettingOptionValues(to values: [Bool]) -> [ExportDatabaseItem] {
        map { database in
            var resetDatabase = database
            resetDatabase.objects = database.objects.map { object in
                var resetObject = object
                resetObject.optionValues = values
                return resetObject
            }
            return resetDatabase
        }
    }

    func maskingUnsupportedOptions(
        columns: [PluginExportOptionColumn],
        supports: @escaping (String, PluginExportObjectKind) -> Bool
    ) -> [ExportDatabaseItem] {
        map { database in
            var maskedDatabase = database
            maskedDatabase.objects = database.objects.map {
                $0.maskingUnsupportedOptions(columns: columns, supports: supports)
            }
            return maskedDatabase
        }
    }
}
