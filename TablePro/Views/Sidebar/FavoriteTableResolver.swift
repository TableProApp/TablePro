//
//  FavoriteTableResolver.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct FavoriteTableBrowseScope: Equatable {
    internal let database: String?
    internal let schema: String?
    internal let listsTablesPerSchema: Bool

    internal init(database: String?, schema: String?, listsTablesPerSchema: Bool) {
        self.database = database?.nilIfEmpty
        self.schema = schema?.nilIfEmpty
        self.listsTablesPerSchema = listsTablesPerSchema
    }

    internal func contains(_ entry: FavoriteTablesStorage.FavoriteEntry) -> Bool {
        entry.database?.nilIfEmpty == database
    }
}

internal struct FavoriteTableCatalog {
    internal struct Source {
        internal enum Coverage: Equatable {
            case everySchema
            case schemas(Set<String>)
        }

        internal let coverage: Coverage
        internal let isCurrent: Bool
        private let tablesByKey: [FavoriteTableKey: TableInfo]

        internal init(tables: [TableInfo], coverage: Coverage, isCurrent: Bool) {
            self.coverage = coverage
            self.isCurrent = isCurrent
            self.tablesByKey = Dictionary(
                tables.map { (FavoriteTableKey(schema: $0.schema, name: $0.name), $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        internal func covers(schema: String) -> Bool {
            switch coverage {
            case .everySchema:
                return true
            case .schemas(let schemas):
                return schemas.contains(schema)
            }
        }

        internal func table(for entry: FavoriteTablesStorage.FavoriteEntry) -> TableInfo? {
            tablesByKey[FavoriteTableKey(schema: entry.schema, name: entry.name)]
        }
    }

    internal static let empty = FavoriteTableCatalog(sources: [])

    internal let sources: [Source]

    internal func hasList(forSchema schema: String) -> Bool {
        sources.contains { $0.covers(schema: schema) }
    }
}

internal struct FavoriteTableKey: Hashable {
    internal let schema: String
    internal let name: String

    internal init(schema: String?, name: String) {
        self.schema = schema ?? ""
        self.name = name
    }
}

internal struct FavoriteTableRow: Equatable, Identifiable {
    internal let entry: FavoriteTablesStorage.FavoriteEntry
    internal let listedTable: TableInfo?
    internal let isVerified: Bool
    internal let otherSchema: String?

    internal var id: String {
        FavoritesOutlineNode.tableId(database: entry.database, schema: entry.schema, name: entry.name)
    }

    internal var knownType: TableInfo.TableType? {
        listedTable?.type
    }

    internal var verifiedType: TableInfo.TableType? {
        isVerified ? knownType : nil
    }

    internal var opensReadOnly: Bool {
        verifiedType.map { !$0.allowsRowEditing } ?? true
    }

    internal var table: TableInfo {
        listedTable ?? TableInfo(name: entry.name, type: .table, rowCount: nil, schema: entry.schema)
    }
}

internal struct FavoriteTableResolution: Equatable {
    internal static let empty = FavoriteTableResolution(rows: [], missingCount: 0, otherDatabaseCount: 0)

    internal let rows: [FavoriteTableRow]
    internal let missingCount: Int
    internal let otherDatabaseCount: Int
}

internal enum FavoriteTableResolver {
    internal static func resolve(
        _ entries: some Sequence<FavoriteTablesStorage.FavoriteEntry>,
        scope: FavoriteTableBrowseScope,
        catalog: FavoriteTableCatalog,
        search: SidebarSearch
    ) -> FavoriteTableResolution {
        var rows: [FavoriteTableRow] = []
        var missingCount = 0
        var otherDatabaseCount = 0
        for entry in entries {
            guard scope.contains(entry) else {
                otherDatabaseCount += 1
                continue
            }
            guard let row = row(for: entry, scope: scope, catalog: catalog) else {
                missingCount += 1
                continue
            }
            rows.append(row)
        }
        let visible = search.isEmpty ? rows : rows.filter { row in
            search.matchesObject(named: row.entry.name, database: scope.database, schema: row.entry.schema)
        }
        return FavoriteTableResolution(
            rows: visible.sorted(by: displayOrder),
            missingCount: missingCount,
            otherDatabaseCount: otherDatabaseCount
        )
    }

    internal static func schemasNeedingLoad(
        _ entries: some Sequence<FavoriteTablesStorage.FavoriteEntry>,
        scope: FavoriteTableBrowseScope,
        catalog: FavoriteTableCatalog
    ) -> Set<String> {
        guard scope.listsTablesPerSchema else { return [] }
        var schemas: Set<String> = []
        for entry in entries where scope.contains(entry) {
            guard let schema = entry.schema?.nilIfEmpty, !catalog.hasList(forSchema: schema) else { continue }
            schemas.insert(schema)
        }
        return schemas
    }

    private static func row(
        for entry: FavoriteTablesStorage.FavoriteEntry,
        scope: FavoriteTableBrowseScope,
        catalog: FavoriteTableCatalog
    ) -> FavoriteTableRow? {
        let schema = entry.schema ?? ""
        let otherSchema = scope.listsTablesPerSchema
            ? SchemaQualifiedName.explicitSchema(entry.schema, implicitSchemaName: scope.schema)
            : nil
        let authorities = catalog.sources.filter { $0.isCurrent && $0.covers(schema: schema) }
        guard authorities.isEmpty else {
            guard let listed = authorities.lazy.compactMap({ $0.table(for: entry) }).first else { return nil }
            return FavoriteTableRow(entry: entry, listedTable: listed, isVerified: true, otherSchema: otherSchema)
        }
        return FavoriteTableRow(
            entry: entry,
            listedTable: catalog.sources.lazy.compactMap { $0.table(for: entry) }.first,
            isVerified: false,
            otherSchema: otherSchema
        )
    }

    private static func displayOrder(_ lhs: FavoriteTableRow, _ rhs: FavoriteTableRow) -> Bool {
        (lhs.entry.name, lhs.entry.schema ?? "") < (rhs.entry.name, rhs.entry.schema ?? "")
    }
}
