//
//  QuickSwitcherViewModel+TableRows.swift
//  TablePro
//

import Foundation

extension QuickSwitcherViewModel {
    /// The schema service answers for every schema it holds a list of, because it refreshes that
    /// list the moment the catalog changes. The all-schema listing fills in the schemas it does not
    /// hold, and may be a read behind for those until it is next asked.
    ///
    /// The schema service keeps its lists until a reload replaces them, so while a database switch
    /// settles it still holds the old database's tables, which would open against the new one.
    /// They count only once the database they were loaded from is the one being browsed.
    ///
    /// `coveredSchemas` names the schemas the schema service answers for even when it found them
    /// empty. Judged from its rows alone, a schema whose last table was dropped would have no rows,
    /// so no say, and the listing's stale copy of that table would come back.
    ///
    /// The listing already honors the schema filter, but the schema service still holds every schema
    /// the sidebar opened before the filter hid it.
    nonisolated static func tables(_ tables: [TableInfo], keeping kept: Set<String>?) -> [TableInfo] {
        guard let kept else { return tables }
        return tables.filter { table in
            guard let schema = table.schema else { return true }
            return kept.contains(schema)
        }
    }

    /// `staleSchemas` are the per-schema lists a catalog change has overtaken and nothing has read
    /// again, because only an expanded tree row reads one again. The listing, which this panel asks
    /// for again after every change, answers for them once it has arrived.
    nonisolated static func mergedTables(
        local loaded: [TableInfo],
        loadedFrom loadedDatabase: String?,
        coveredSchemas: Set<String>,
        staleSchemas: Set<String>,
        listing: [TableInfo]?,
        browsing database: String?
    ) -> [TableInfo] {
        let isCurrent = loadedDatabase == database
        let overtaken = listing == nil ? [] : staleSchemas
        let local = isCurrent ? loaded.filter { !overtaken.contains($0.schema ?? "") } : []
        let authoritative = (isCurrent ? coveredSchemas.subtracting(overtaken) : [])
            .union(local.map { $0.schema ?? "" })
        var seen: Set<TableIdentity> = []
        return (local + (listing ?? []).filter { !authoritative.contains($0.schema ?? "") })
            .filter { seen.insert(TableIdentity(schema: $0.schema ?? "", name: $0.name)).inserted }
    }

    private struct TableIdentity: Hashable {
        let schema: String
        let name: String
    }

    /// A table outside the browsed schema names its schema, and one inside it does not, the way
    /// SQL written against the browsed schema would spell them.
    nonisolated static func makeTableItems(
        _ tables: [TableInfo],
        database: String?,
        connectionSwitchesDatabases: Bool,
        browseSchema: String?,
        openTables: Set<QuickSwitcherOpenTable>
    ) -> [QuickSwitcherItem] {
        let qualifier = QuickSwitcherFrecencyKey.DatabaseQualifier(
            database: database,
            connectionSwitchesDatabases: connectionSwitchesDatabases
        )
        var listedKeys: Set<String> = []
        return tables.compactMap { table in
            let frecencyKey = QuickSwitcherFrecencyKey.table(
                name: table.name, schema: table.schema ?? browseSchema, in: qualifier
            )
            guard listedKeys.insert(frecencyKey).inserted else { return nil }
            let presentation = tablePresentation(for: table.type)
            let otherSchema = SchemaQualifiedName.explicitSchema(table.schema, implicitSchemaName: browseSchema)
            let subtitle = [otherSchema, presentation.subtitle]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: ", ")
            return QuickSwitcherItem(
                frecencyKey: frecencyKey,
                name: table.name,
                kind: presentation.kind,
                subtitle: subtitle,
                isOpenInTab: openTables.contains(
                    QuickSwitcherOpenTable(
                        database: database,
                        schema: table.schema,
                        name: table.name,
                        browsingDatabase: database,
                        browsingSchema: browseSchema
                    )
                ),
                isReadOnly: !table.type.allowsRowEditing,
                schemaName: table.schema,
                databaseName: database,
                tableType: table.type,
                isOutsideBrowsedSchema: otherSchema != nil
            )
        }
    }

    nonisolated static func makeCrossConnectionItems(
        tables: [TableInfo],
        target: QuickSwitcherTarget,
        connectionSwitchesDatabases: Bool
    ) -> [QuickSwitcherItem] {
        let qualifier = QuickSwitcherFrecencyKey.DatabaseQualifier(
            database: target.databaseName,
            connectionSwitchesDatabases: connectionSwitchesDatabases
        )
        var listedKeys: Set<String> = []
        return tables.compactMap { table in
            let resolvedTarget = QuickSwitcherTarget(
                connectionId: target.connectionId,
                connectionName: target.connectionName,
                databaseName: target.databaseName,
                schemaName: table.schema ?? target.schemaName,
                databaseDisplayName: target.databaseDisplayName,
                pathFieldRole: target.pathFieldRole
            )
            let frecencyKey = QuickSwitcherFrecencyKey.table(
                name: table.name, schema: resolvedTarget.schemaName, in: qualifier
            )
            guard listedKeys.insert(frecencyKey).inserted else { return nil }
            let presentation = tablePresentation(for: table.type)
            return QuickSwitcherItem(
                frecencyKey: frecencyKey,
                name: table.name,
                kind: presentation.kind,
                subtitle: connectionPath(for: resolvedTarget),
                isReadOnly: !table.type.allowsRowEditing,
                target: resolvedTarget,
                tableType: table.type
            )
        }
    }

    nonisolated private static func tablePresentation(
        for type: TableInfo.TableType
    ) -> (kind: QuickSwitcherItemKind, subtitle: String) {
        switch type {
        case .table:
            return (.table, "")
        case .view:
            return (.view, String(localized: "View"))
        case .materializedView:
            return (.view, String(localized: "Materialized View"))
        case .foreignTable:
            return (.table, String(localized: "Foreign Table"))
        case .systemTable:
            return (.systemTable, String(localized: "System"))
        case .partitionedTable:
            return (.table, String(localized: "Partitioned Table"))
        case .externalTable:
            return (.table, String(localized: "External Table"))
        case .sequence:
            return (.table, String(localized: "Sequence"))
        }
    }
}
