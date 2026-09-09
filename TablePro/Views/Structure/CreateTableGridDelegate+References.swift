//
//  CreateTableGridDelegate+References.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The Foreign Keys grid's three reference cells offer what the database actually holds.
///
/// They were free text, so the only way to point a key at a table was to spell its name and its
/// columns from memory, and a typo produced a server error at Create time rather than a list that
/// could not be wrong. Every list still ends in `Custom…`, because a table the sidebar has not
/// loaded has to stay reachable.
extension CreateTableGridDelegate {
    func dataGridMenuOptions(forRow row: Int, columnIndex: Int) -> [GridMenuOption]? {
        guard structureTab == .foreignKeys,
              row >= 0, row < structureChangeManager.workingForeignKeys.count else { return nil }
        let foreignKey = structureChangeManager.workingForeignKeys[row]

        switch columnIndex {
        case 1:
            return listOptions(
                names: structureChangeManager.workingColumns.map(\.name).filter { !$0.isEmpty },
                appendingTo: foreignKey.columns,
                loading: false
            )
        case 2:
            return replaceOptions(names: referencedTableNames(schema: foreignKey.referencedSchema))
        case 3:
            let table = foreignKey.referencedTable.trimmingCharacters(in: .whitespaces)
            guard !table.isEmpty else {
                return [.custom(title: String(localized: "Custom…"))]
            }
            return listOptions(
                names: referencedColumnNames(of: table, schema: foreignKey.referencedSchema),
                appendingTo: foreignKey.referencedColumns,
                loading: isLoadingReferencedColumns(of: table, schema: foreignKey.referencedSchema)
            )
        default:
            return nil
        }
    }

    /// A cell holding a comma-separated list appends rather than replaces, so each entry carries the
    /// whole new list as the value it writes. That keeps the menu machinery untouched: it still just
    /// sets the cell to the selected option's SQL.
    private func listOptions(names: [String], appendingTo current: [String], loading: Bool) -> [GridMenuOption] {
        let joined = current.joined(separator: ", ")
        return ForeignKeyReferenceVocabulary.options(names: names, loading: loading).map { option in
            guard case .value(let title, _) = option else { return option }
            return .value(title: title, sql: ForeignKeyReferenceVocabulary.appending(title, to: joined))
        }
    }

    private func replaceOptions(names: [String]) -> [GridMenuOption] {
        ForeignKeyReferenceVocabulary.options(names: names, loading: false)
    }

    /// Views are left out. `SchemaService.tables` returns them alongside tables on every engine
    /// that reports both, SQLite included, and a foreign key cannot target one: offering it makes a
    /// constraint the server refuses.
    private func referencedTableNames(schema: String?) -> [String] {
        let service = SchemaService.shared
        let scopeSchema = schema ?? schemaName
        let tables = scopeSchema.map { service.tables(for: connection.id, schema: $0) }
            ?? service.tables(for: connection.id)
        return tables.filter { $0.type.isForeignKeyTarget }.map(\.name)
    }

    /// Cached by table name, so a result that arrives after the user has moved on can only ever
    /// populate the list for the table it was fetched for. That is why no generation token is
    /// needed here: a late answer is not wrong, it is just early for next time.
    private func referencedColumnNames(of table: String, schema: String?) -> [String] {
        if let cached = referencedColumnCache[cacheKey(table: table, schema: schema)] {
            return cached
        }
        loadReferencedColumns(of: table, schema: schema)
        return []
    }

    private func isLoadingReferencedColumns(of table: String, schema: String?) -> Bool {
        referencedColumnCache[cacheKey(table: table, schema: schema)] == nil
    }

    func prefetchReferencedColumns(of table: String, schema: String?) {
        let trimmed = table.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, referencedColumnCache[cacheKey(table: trimmed, schema: schema)] == nil else { return }
        loadReferencedColumns(of: trimmed, schema: schema)
    }

    private func loadReferencedColumns(of table: String, schema: String?) {
        let key = cacheKey(table: table, schema: schema)
        guard !referencedColumnRequests.contains(key) else { return }
        guard let scope = DatabaseManager.shared.browseScope(for: connection.id) else { return }
        referencedColumnRequests.insert(key)

        Task { @MainActor in
            defer { referencedColumnRequests.remove(key) }
            let columns = try? await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                try await driver.fetchColumns(table: table, schema: schema)
            }
            referencedColumnCache[key] = (columns ?? []).map(\.name)
            onReferenceListsChanged?()
        }
    }

    /// The row's own Ref Schema, not the draft's. Two rows pointing at `public.users` and
    /// `audit.users` are different tables with different columns, and one key for both hands the
    /// second row the first one's list.
    private func cacheKey(table: String, schema: String?) -> String {
        "\(connection.id.uuidString)|\(schema ?? schemaName ?? "")|\(table)"
    }
}
