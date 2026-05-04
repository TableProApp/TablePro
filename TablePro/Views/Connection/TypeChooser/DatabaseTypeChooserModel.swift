//
//  DatabaseTypeChooserModel.swift
//  TablePro
//

import Foundation
import Observation

@MainActor
@Observable
final class DatabaseTypeChooserModel {
    var searchText: String = ""
    var highlightedType: DatabaseType?

    private let allTypes: [DatabaseType]

    init(types: [DatabaseType]? = nil) {
        if let types {
            self.allTypes = types
        } else {
            self.allTypes = PluginManager.shared.allAvailableDatabaseTypes
        }
    }

    func preselect(_ type: DatabaseType?) {
        highlightedType = type
    }

    var filteredTypes: [DatabaseType] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allTypes }
        let needle = trimmed.lowercased()
        return allTypes.filter { type in
            if type.rawValue.lowercased().contains(needle) { return true }
            if let tagline = type.tagline, tagline.lowercased().contains(needle) { return true }
            if type.category.displayName.lowercased().contains(needle) { return true }
            return false
        }
    }

    var groupedTypes: [(category: DatabaseCategory, types: [DatabaseType])] {
        let grouped = Dictionary(grouping: filteredTypes, by: { $0.category })
        return grouped
            .map { (category: $0.key, types: $0.value.sorted { $0.rawValue < $1.rawValue }) }
            .sorted { $0.category.sortOrder < $1.category.sortOrder }
    }
}
