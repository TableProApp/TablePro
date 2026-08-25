//
//  FavoriteDatabaseGrouping.swift
//  TablePro
//

import Foundation

internal enum FavoriteDatabaseGrouping {
    internal static func groups(
        entries: Set<FavoriteDatabaseEntry>,
        searchText: String,
        filter: FavoriteDatabaseEnvironmentFilter
    ) -> [FavoriteDatabaseGroup] {
        let filtered = entries.filter { entry in
            guard filter.environment == nil || entry.environment == filter.environment else { return false }
            guard !searchText.isEmpty else { return true }
            return entry.database.localizedStandardContains(searchText)
        }

        return FavoriteDatabaseEnvironment.allCases.compactMap { environment in
            let matching = filtered
                .filter { $0.environment == environment }
                .sorted {
                    let comparison = $0.database.localizedStandardCompare($1.database)
                    if comparison != .orderedSame { return comparison == .orderedAscending }
                    return $0.id < $1.id
                }
            guard !matching.isEmpty else { return nil }
            return FavoriteDatabaseGroup(environment: environment, entries: matching)
        }
    }
}
