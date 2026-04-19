//
//  ExportModels.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// MARK: - Export Mode

/// Defines the export mode: either exporting database tables or in-memory query results.
enum ExportMode {
    case tables(connection: DatabaseConnection, preselectedTables: Set<String>)
    case queryResults(connection: DatabaseConnection, rowBuffer: RowBuffer, suggestedFileName: String)
    case streamingQuery(connection: DatabaseConnection, query: String, suggestedFileName: String)
}

// MARK: - Export Configuration

@MainActor
struct ExportConfiguration {
    var formatId: String = "csv"
    var fileName: String = "export"

    var fullFileName: String {
        guard let plugin = PluginManager.shared.exportPlugins[formatId] else {
            return "\(fileName).\(formatId)"
        }
        return "\(fileName).\(plugin.currentFileExtension)"
    }

    var fileExtension: String {
        guard let plugin = PluginManager.shared.exportPlugins[formatId] else {
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
