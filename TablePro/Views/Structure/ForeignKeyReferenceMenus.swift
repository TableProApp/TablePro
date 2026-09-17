//
//  ForeignKeyReferenceMenus.swift
//  TablePro
//

import Foundation
import os
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
    private let databaseType: DatabaseType

    /// The schema the grid is browsing, used when a row names no Ref Schema of its own.
    var schemaName: String?

    /// The scope the grid's own tab is bound to, which every reference read starts from. A tab stays
    /// on the database it opened while the sidebar moves. Nil for a grid with no tab behind it, such
    /// as the Create Table draft, which creates its table wherever the connection is browsing.
    var origin: DatabaseScope?

    /// Fired when a referenced table's columns arrive. A menu built before the fetch landed shows
    /// `Loading…` and nothing else would rebuild it until an unrelated edit.
    var onListsChanged: (() -> Void)?

    /// Which list, in which container. The kind is part of the key because a container's table list
    /// and one of its tables' column lists are both `[String]`: keyed on the container alone they
    /// overwrite each other, and the Ref Table menu starts offering column names.
    private struct ListKey: Hashable {
        enum Kind: Hashable {
            case tables
            case columns(String)
        }

        let database: String
        let schema: String?
        let kind: Kind
    }

    private var lists: [ListKey: [String]] = [:]

    /// Keys whose read failed. Separate from `lists` because an empty list and a read that could not
    /// run are different answers, and storing the failure as `[]` made the menu offer nothing but
    /// Custom for the life of the tab, with no error and no retry.
    private var failedKeys: Set<ListKey> = []
    private var inFlight: Set<ListKey> = []

    private enum ListState {
        case loading
        case loaded([String])
        case failed

        var names: [String] {
            guard case .loaded(let names) = self else { return [] }
            return names
        }

        var isLoading: Bool {
            guard case .loading = self else { return false }
            return true
        }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "ForeignKeyReferenceMenus")

    private let provider: any ScopedMetadataProviding

    /// Read per use rather than stored, because a plugin's capabilities settle when it loads and a
    /// slot resolved at construction would freeze whatever was known before that.
    private let resolveSlot: @MainActor (DatabaseType) -> EngineNamespaceSlot

    init(
        connectionId: UUID,
        databaseType: DatabaseType,
        provider: any ScopedMetadataProviding = DatabaseManager.shared,
        resolveSlot: @escaping @MainActor (DatabaseType) -> EngineNamespaceSlot =
            EngineNamespaceSlot.init(databaseType:)
    ) {
        self.connectionId = connectionId
        self.databaseType = databaseType
        self.provider = provider
        self.resolveSlot = resolveSlot
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
                state: .loaded(tableColumns)
            )
        case 2:
            let tables = listState(.tables, schema: foreignKey.referencedSchema)
            return reporting(
                tables,
                over: ForeignKeyReferenceVocabulary.options(names: tables.names, loading: tables.isLoading)
            )
        case 3:
            let table = foreignKey.referencedTable.trimmingCharacters(in: .whitespaces)
            guard !table.isEmpty else {
                return [.custom(title: String(localized: "Custom…"))]
            }
            let schema = foreignKey.referencedSchema
            let state = listState(.columns(table), schema: schema)
            return listOptions(
                names: state.names,
                appendingTo: foreignKey.referencedColumns,
                state: state
            )
        default:
            return nil
        }
    }

    /// Drops what a schema refresh can have changed. The column lists survive: a refresh that
    /// changed a referenced table's columns did not change which tables exist, and re-reading every
    /// one of them on every refresh costs a round trip per open menu.
    func invalidateTableLists() {
        for key in lists.keys where key.kind == .tables {
            lists.removeValue(forKey: key)
        }
        failedKeys = failedKeys.filter { $0.kind != .tables }
    }

    /// Warms the list before the chevron is opened. A key that already failed is left alone: the
    /// retry belongs to the user reopening the menu, not to a render.
    func prefetchReferencedColumns(of table: String, schema: String?) {
        let trimmed = table.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let resolved = resolvedList(.columns(trimmed), schema: schema) else { return }
        guard lists[resolved.key] == nil, !failedKeys.contains(resolved.key) else { return }
        load(resolved.key, from: resolved.target)
    }

    /// A cell holding a comma-separated list appends rather than replaces, so each entry carries the
    /// whole new list as the value it writes. That keeps the menu machinery untouched: it still just
    /// sets the cell to the selected option's SQL.
    private func listOptions(
        names: [String],
        appendingTo current: [String],
        state: ListState
    ) -> [GridMenuOption] {
        let joined = current.joined(separator: ", ")
        let options = ForeignKeyReferenceVocabulary
            .options(names: names, loading: state.isLoading)
            .map { option -> GridMenuOption in
                guard case .value(let title, _) = option else { return option }
                return .value(title: title, sql: ForeignKeyReferenceVocabulary.appending(title, to: joined))
            }
        return reporting(state, over: options)
    }

    /// A read that could not run and a container that holds nothing produce the same empty list, so
    /// the menu says which it was rather than offering nothing and looking settled.
    private func reporting(_ state: ListState, over options: [GridMenuOption]) -> [GridMenuOption] {
        guard case .failed = state else { return options }
        return [.sectionHeader(String(localized: "Couldn't read the referenced table"))] + options
    }

    /// Reopening the menu is the retry: a failure is reported once and the read starts again behind
    /// it, so a list that was briefly unreachable fills in by the next open.
    private func listState(_ kind: ListKey.Kind, schema: String?) -> ListState {
        guard let resolved = resolvedList(kind, schema: schema) else { return .loading }
        if let cached = lists[resolved.key] { return .loaded(cached) }
        load(resolved.key, from: resolved.target)
        guard failedKeys.remove(resolved.key) != nil else { return .loading }
        return .failed
    }

    /// Read through the tab's own driver rather than `SchemaService`, whose per-schema lists are
    /// filled only for an engine that groups its tree by schema under a database. On every other
    /// engine that store is never written, so a Ref Table menu asking it for a named schema got an
    /// empty list on PostgreSQL, MySQL and the rest, whatever the connection actually holds.
    private func load(_ key: ListKey, from target: DatabaseScope) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)

        Task { @MainActor in
            defer { inFlight.remove(key) }
            do {
                let names = try await names(for: key.kind, in: target)
                failedKeys.remove(key)
                lists[key] = names
            } catch {
                Self.logger.error("Reference list read failed: \(error.localizedDescription)")
                failedKeys.insert(key)
            }
            onListsChanged?()
        }
    }

    /// Views are left out of the table list. Every engine that reports both returns them alongside
    /// tables, SQLite included, and a foreign key cannot target one: offering it makes a constraint
    /// the server refuses.
    private func names(for kind: ListKey.Kind, in target: DatabaseScope) async throws -> [String] {
        switch kind {
        case .tables:
            let tables = try await provider.withMetadataDriver(scope: target) { driver in
                try await driver.fetchTables(schema: target.schema)
            }
            return tables.filter { $0.type.isForeignKeyTarget }.map(\.name)
        case .columns(let table):
            let columns = try await provider.withMetadataDriver(scope: target) { driver in
                try await driver.fetchColumns(table: table, schema: target.schema)
            }
            return columns.map(\.name)
        }
    }

    /// The row names its target in whatever the engine's catalog calls a schema, which on an engine
    /// with no schema layer is a database, so it goes through `ForeignKeyTargetScope` rather than
    /// into the schema slot, where it would be inert.
    private func targetScope(for schema: String?) -> DatabaseScope? {
        guard let origin = origin ?? provider.browseScope(for: connectionId) else {
            return nil
        }
        return ForeignKeyTargetScope.resolve(
            origin: origin, referencedSchema: schema, slot: resolveSlot(databaseType)
        )
    }

    /// The row's own Ref Schema, not the grid's, and resolved the way the read is. Two rows
    /// pointing at `public.users` and `audit.users` are different tables with different columns, and
    /// one key for both hands the second row the first one's list. Keying on the raw value instead
    /// collapses two databases to one entry on an engine whose catalog calls a database a schema.
    ///
    /// The key and the scope it was resolved from travel together: the key has already collapsed a
    /// schema-less engine's reference into its database, so re-deriving the scope from the key would
    /// read the tab's own container instead of the referenced one.
    ///
    /// Nil where no scope can be resolved at all, which is a connection with nothing to read rather
    /// than a list that happens to be empty, so nothing is cached under it.
    private func resolvedList(
        _ kind: ListKey.Kind,
        schema: String?
    ) -> (key: ListKey, target: DatabaseScope)? {
        guard let target = targetScope(for: schema) else { return nil }
        let key = ListKey(database: target.database, schema: target.schema ?? schemaName, kind: kind)
        return (key, target)
    }
}
