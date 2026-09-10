//
//  ForeignKeyReferenceMenus.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The menus behind the Foreign Keys grid's Columns, Ref Table and Ref Columns cells.
///
/// Owned by both grid delegates rather than written twice. `StructureRowProvider` decides which
/// columns carry a chevron and it serves the Create Table tab and the Structure tab alike, so a
/// reference menu that exists on one and not the other is a cell whose chevron opens the data
/// grid's boolean fallback: a `1` / `0` menu that writes a digit into Ref Table.
@MainActor
final class ForeignKeyReferenceMenus {
    /// Grid columns on the Foreign Keys tab whose list depends on the row: 1 Columns, 2 Ref Table,
    /// 3 Ref Columns. Read by `StructureRowProvider` so the chevron and the menu agree.
    static let rowDependentColumns: Set<Int> = [1, 2, 3]

    private let connectionId: UUID

    /// The schema the grid is browsing, used when a row names no Ref Schema of its own.
    var schemaName: String?

    /// Fired when a referenced table's columns arrive. A menu built before the fetch landed shows
    /// `Loading…` and nothing else would rebuild it until an unrelated edit.
    var onListsChanged: (() -> Void)?

    private var columnCache: [String: [String]] = [:]
    private var inFlight: Set<String> = []

    init(connectionId: UUID) {
        self.connectionId = connectionId
    }

    /// - Parameter tableColumns: the columns of the table being edited, which the referencing
    ///   Columns cell offers. On the Structure tab these are the working columns of the table on
    ///   screen; on Create Table they are the ones the draft defines.
    func options(
        columnIndex: Int,
        foreignKey: EditableForeignKeyDefinition,
        tableColumns: [String]
    ) -> [GridMenuOption]? {
        switch columnIndex {
        case 1:
            return listOptions(
                names: tableColumns.filter { !$0.isEmpty },
                appendingTo: foreignKey.columns,
                loading: false
            )
        case 2:
            return ForeignKeyReferenceVocabulary.options(
                names: referencedTableNames(schema: foreignKey.referencedSchema), loading: false
            )
        case 3:
            let table = foreignKey.referencedTable.trimmingCharacters(in: .whitespaces)
            guard !table.isEmpty else {
                return [.custom(title: String(localized: "Custom…"))]
            }
            let schema = foreignKey.referencedSchema
            return listOptions(
                names: referencedColumnNames(of: table, schema: schema),
                appendingTo: foreignKey.referencedColumns,
                loading: columnCache[cacheKey(table: table, schema: schema)] == nil
            )
        default:
            return nil
        }
    }

    func prefetchReferencedColumns(of table: String, schema: String?) {
        let trimmed = table.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, columnCache[cacheKey(table: trimmed, schema: schema)] == nil else { return }
        loadReferencedColumns(of: trimmed, schema: schema)
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

    /// Views are left out. `SchemaService.tables` returns them alongside tables on every engine that
    /// reports both, SQLite included, and a foreign key cannot target one: offering it makes a
    /// constraint the server refuses.
    private func referencedTableNames(schema: String?) -> [String] {
        let service = SchemaService.shared
        let scopeSchema = schema ?? schemaName
        let tables = scopeSchema.map { service.tables(for: connectionId, schema: $0) }
            ?? service.tables(for: connectionId)
        return tables.filter { $0.type.isForeignKeyTarget }.map(\.name)
    }

    private func referencedColumnNames(of table: String, schema: String?) -> [String] {
        if let cached = columnCache[cacheKey(table: table, schema: schema)] {
            return cached
        }
        loadReferencedColumns(of: table, schema: schema)
        return []
    }

    private func loadReferencedColumns(of table: String, schema: String?) {
        let key = cacheKey(table: table, schema: schema)
        guard !inFlight.contains(key) else { return }
        guard let scope = DatabaseManager.shared.browseScope(for: connectionId) else { return }
        inFlight.insert(key)

        Task { @MainActor in
            defer { inFlight.remove(key) }
            let columns = try? await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                try await driver.fetchColumns(table: table, schema: schema)
            }
            columnCache[key] = (columns ?? []).map(\.name)
            onListsChanged?()
        }
    }

    /// The row's own Ref Schema, not the grid's. Two rows pointing at `public.users` and
    /// `audit.users` are different tables with different columns, and one key for both hands the
    /// second row the first one's list.
    private func cacheKey(table: String, schema: String?) -> String {
        "\(connectionId.uuidString)|\(schema ?? schemaName ?? "")|\(table)"
    }
}
