//
//  DatabaseTreeFilter.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum DatabaseTreeFilter {
    static func matches(_ query: String, _ candidate: String) -> Bool {
        SidebarNameFilter.matches(query: query, candidate: candidate)
    }

    static func filteredTables(_ tables: [TableInfo], searchText: String) -> [TableInfo] {
        let matched = SidebarNameFilter.ranked(tables, query: searchText, name: { $0.name })
        return deduplicated(matched, by: \.id)
    }

    static func filteredRoutines(_ routines: [RoutineInfo], searchText: String) -> [RoutineInfo] {
        let matched = SidebarNameFilter.ranked(routines, query: searchText, name: { $0.name })
        return deduplicated(matched, by: \.id)
    }

    /// A schema whose tables have not loaded yet cannot be judged, so it stays visible. Reading an
    /// unloaded schema as an empty one hides it for the whole life of the filter and blanks the
    /// pane while the search-driven load is still running.
    static func hierarchicalSchemaIsVisible(
        _ schema: String,
        searchText: String,
        isLoaded: Bool,
        tables: [TableInfo]
    ) -> Bool {
        if matches(searchText, schema) { return true }
        guard isLoaded else { return true }
        return !filteredTables(tables, searchText: searchText).isEmpty
    }

    /// A schema the search matched by name shows everything inside it. Filtering its tables by the
    /// same query leaves the matched schema reporting no items.
    static func hierarchicalTables(_ tables: [TableInfo], schema: String, searchText: String) -> [TableInfo] {
        matches(searchText, schema) ? tables : filteredTables(tables, searchText: searchText)
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
