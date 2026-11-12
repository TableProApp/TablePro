//
//  TableDetailTree.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Which detail lists an engine can answer. A group it cannot fill is not listed: an empty
/// Triggers group would claim the table has none.
internal struct TableDetailCapabilities: Equatable, Sendable {
    let foreignKeys: Bool
    let checks: Bool
    let triggers: Bool

    init(foreignKeys: Bool, checks: Bool, triggers: Bool) {
        self.foreignKeys = foreignKeys
        self.checks = checks
        self.triggers = triggers
    }

    init(databaseType: DatabaseType) {
        self.init(
            foreignKeys: databaseType.supportsForeignKeys,
            checks: databaseType.supportsCheckConstraints,
            triggers: databaseType.supportsTriggers
        )
    }
}

internal enum TableDetailGroupResolver {
    /// A sequence holds no columns, indexes or constraints, and a triangle that opens on nothing is
    /// the bug the outline's expandability gate exists to prevent.
    static func listsDetails(of type: TableInfo.TableType) -> Bool {
        type != .sequence
    }

    static func groups(
        for type: TableInfo.TableType,
        capabilities: TableDetailCapabilities,
        showsPartitions: Bool
    ) -> [TableDetailGroupKind] {
        guard listsDetails(of: type) else { return [] }
        let isTable = type == .table || type == .partitionedTable
        var groups: [TableDetailGroupKind] = [.columns]
        if isTable || type == .materializedView { groups.append(.indexes) }
        if isTable, capabilities.foreignKeys { groups.append(.foreignKeys) }
        if isTable, capabilities.checks { groups.append(.checks) }
        if isTable, capabilities.triggers { groups.append(.triggers) }
        if type == .partitionedTable, showsPartitions { groups.append(.partitions) }
        return groups
    }

    /// A failed read is not asked for again until the next change, so the user's own reopening is
    /// the retry. A restore pass never retries, or every reload would repeat a read the server refuses.
    static func readsOnDisclosure(
        needsFetch: Bool,
        phase: MetadataLoadPhase,
        origin: DatabaseTreeFilter.DisclosureOrigin
    ) -> Bool {
        needsFetch || (origin == .user && phase.failureMessage != nil)
    }
}

internal enum TableDetailRows {
    enum Row: Equatable {
        case detail(DatabaseTreeTableDetailRef)
        case trigger(DatabaseTreeTriggerRef)
    }

    struct Entry: Equatable {
        let key: String
        let row: Row
    }

    static func entries(for list: TableDetailList, table: DatabaseTreeTableRef) -> [Entry] {
        switch list {
        case .triggers(let triggers):
            let keys = uniqueKeys(for: triggers.map { $0.name })
            return zip(keys, triggers).map { key, trigger in
                Entry(key: key, row: .trigger(DatabaseTreeTriggerRef(
                    database: table.database,
                    schema: table.schema,
                    trigger: owned(trigger, by: table),
                    listedUnderTable: true
                )))
            }
        case .columns, .indexes, .foreignKeys, .checks:
            let items = items(in: list)
            let keys = uniqueKeys(for: items.map { $0.name })
            return zip(keys, items).map { key, item in
                Entry(key: key, row: .detail(DatabaseTreeTableDetailRef(table: table, item: item)))
            }
        }
    }

    static func items(in list: TableDetailList) -> [TableDetailItem] {
        switch list {
        case .columns(let columns): columns.map(TableDetailItem.column)
        case .indexes(let indexes): indexes.map(TableDetailItem.index)
        case .foreignKeys(let keys): EditableForeignKeyDefinition.grouping(keys).map(TableDetailItem.foreignKey)
        case .checks(let checks): checks.map(TableDetailItem.check)
        case .triggers: []
        }
    }

    /// A row's node id ends in this key, and `NSOutlineView` must get each node once. Unnamed checks
    /// and same-named triggers are real, so a repeat gets its position after the name.
    static func uniqueKeys(for names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { name in
            let occurrence = seen[name, default: 0] + 1
            seen[name] = occurrence
            return occurrence == 1 ? name : "\(name)\u{1}\(occurrence)"
        }
    }

    /// Show DDL and Copy Table Name read the trigger's own table and schema, and a per-table read
    /// may leave them out because the caller already named the table.
    static func owned(_ trigger: TriggerInfo, by table: DatabaseTreeTableRef) -> TriggerInfo {
        let tableName = trigger.table?.nilIfEmpty ?? table.table.name
        let schema = trigger.schema?.nilIfEmpty ?? table.qualifyingSchema
        guard tableName != trigger.table || schema != trigger.schema else { return trigger }
        return TriggerInfo(
            name: trigger.name,
            timing: trigger.timing,
            event: trigger.event,
            statement: trigger.statement,
            enabled: trigger.enabled,
            table: tableName,
            schema: schema,
            orientation: trigger.orientation,
            definition: trigger.definition,
            attributes: trigger.attributes
        )
    }
}

extension TableDetailList {
    /// What a group's caption counts: rows as listed, so a two-column key counts once.
    var count: Int {
        if case .triggers(let triggers) = self { return triggers.count }
        return TableDetailRows.items(in: self).count
    }
}
