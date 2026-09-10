//
//  DatabaseTypeChooserModel.swift
//  TablePro
//

import Foundation
import Observation

@MainActor
@Observable
final class DatabaseTypeChooserModel {
    var searchText: String = "" {
        didSet { settleHighlight() }
    }

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

    /// The rows as the list draws them, which is category order and then alphabetical, not the
    /// order `filteredTypes` happens to produce. Arrowing has to follow what is on screen.
    var orderedTypes: [DatabaseType] {
        groupedTypes.flatMap(\.types)
    }

    /// The match a query most plausibly meant, or nil when the query matched nothing.
    ///
    /// Ranked, and that is the whole point: the filter also matches taglines and category names, so
    /// the first row on screen is routinely not the best answer. "PostgreSQL" matches CockroachDB
    /// ("Distributed SQL, PostgreSQL-compatible") and PGlite, and CockroachDB sorts ahead of
    /// PostgreSQL alphabetically inside Relational. Arming the first row would let Return commit a
    /// driver the user never looked at, and on an existing connection a type change resets its
    /// credentials, SSL, driver options and transport.
    var bestMatch: DatabaseType? {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let candidates = orderedTypes
        if let exact = candidates.first(where: { $0.rawValue.lowercased() == trimmed }) {
            return exact
        }
        if let prefixed = candidates.first(where: { $0.rawValue.lowercased().hasPrefix(trimmed) }) {
            return prefixed
        }
        if let named = candidates.first(where: { $0.rawValue.lowercased().contains(trimmed) }) {
            return named
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    func moveHighlight(by offset: Int) {
        let items = orderedTypes
        guard !items.isEmpty else { return }
        guard let current = highlightedType, let index = items.firstIndex(of: current) else {
            highlightedType = offset > 0 ? items.first : items.last
            return
        }
        let target = index + offset
        guard items.indices.contains(target) else { return }
        highlightedType = items[target]
    }

    /// Keeps a highlight the query still shows, and otherwise arms the best match, or nothing.
    ///
    /// Never falls back to the first row: a query that matched only taglines leaves the highlight
    /// nil and Continue dimmed, which is correct, because no row is a defensible default there.
    private func settleHighlight() {
        if let current = highlightedType, orderedTypes.contains(current) { return }
        highlightedType = bestMatch
    }
}
