//
//  DatabaseTreeFilter.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum DatabaseTreeFilter {
    static func matches(_ query: String, _ candidate: String) -> Bool {
        FuzzyMatcher.matches(query: query, candidate: candidate)
    }

    static func filteredTables(_ tables: [TableInfo], searchText: String) -> [TableInfo] {
        let matched = searchText.isEmpty ? tables : tables.filter { matches(searchText, $0.name) }
        return deduplicated(matched, by: \.id)
    }

    static func filteredRoutines(_ routines: [RoutineInfo], searchText: String) -> [RoutineInfo] {
        let matched = searchText.isEmpty ? routines : routines.filter { matches(searchText, $0.name) }
        return deduplicated(matched, by: \.id)
    }

    static func visibleSchemas(
        _ schemas: [String],
        systemSchemas: Set<String>,
        searchText: String,
        contentMatches: (String) -> Bool
    ) -> [String] {
        let nonSystem = schemas.filter { !systemSchemas.contains($0) }
        let matched = searchText.isEmpty
            ? nonSystem
            : nonSystem.filter { matches(searchText, $0) || contentMatches($0) }
        return deduplicated(matched, by: { $0 })
    }

    private static func deduplicated<Element, Key: Hashable>(
        _ items: [Element],
        by key: (Element) -> Key
    ) -> [Element] {
        var seen = Set<Key>()
        return items.filter { seen.insert(key($0)).inserted }
    }
}
