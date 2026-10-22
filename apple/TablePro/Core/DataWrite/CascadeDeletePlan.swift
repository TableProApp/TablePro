import Foundation
import TableProPluginKit

struct ReferencingKey: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case cascade
        case setNull
        case setDefault
        case restrict
        // NO ACTION, and any value the catalog reports that is not known here.
        case noAction
    }

    let name: String
    let table: String
    let columns: [String]
    let referencedTable: String
    let referencedColumns: [String]
    let action: Action

    static func action(forCatalogValue value: String) -> Action {
        // SQL Server's catalog writes `SET_NULL` and `NO_ACTION`.
        let normalized = value
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        switch normalized {
        case "CASCADE": return .cascade
        case "SET NULL": return .setNull
        case "SET DEFAULT": return .setDefault
        case "RESTRICT": return .restrict
        default: return .noAction
        }
    }

    // Catalogs report one row per column pair, so a composite key is regrouped by its name.
    static func keys(
        from foreignKeys: [String: [ForeignKeyInfo]],
        pointingInto scope: DatabaseScope,
        slot: EngineNamespaceSlot
    ) -> [ReferencingKey] {
        var keys: [ReferencingKey] = []
        for table in foreignKeys.keys.sorted() {
            var order: [String] = []
            var parts: [String: [ForeignKeyInfo]] = [:]
            for (offset, info) in (foreignKeys[table] ?? []).enumerated()
            where points(info, into: scope, slot: slot) {
                let id = info.name.isEmpty ? "#\(offset)" : info.name
                if parts[id] == nil { order.append(id) }
                parts[id, default: []].append(info)
            }
            for id in order {
                guard let group = parts[id], let first = group.first else { continue }
                keys.append(
                    ReferencingKey(
                        name: first.name,
                        table: table,
                        columns: group.map(\.column),
                        referencedTable: first.referencedTable,
                        referencedColumns: group.map(\.referencedColumn),
                        action: action(forCatalogValue: first.onDelete)
                    )
                )
            }
        }
        return keys
    }

    // A key into another schema or database names a different table that shares the name.
    private static func points(_ info: ForeignKeyInfo, into scope: DatabaseScope, slot: EngineNamespaceSlot) -> Bool {
        let target = ForeignKeyTargetScope.resolve(
            origin: scope,
            referencedDatabase: info.referencedDatabase,
            referencedSchema: info.referencedSchema,
            slot: slot
        )
        switch slot {
        case .schema:
            return target.database == scope.database && (scope.schema == nil || target.schema == scope.schema)
        case .database:
            return target.database == scope.database
        case .unqualified:
            return true
        }
    }
}

indirect enum CascadeRowSet: Hashable, Sendable {
    case keyed(table: String, columns: [String], values: [[String]])
    case referencing(table: String, columns: [String], parentColumns: [String], parent: CascadeRowSet)

    var table: String {
        switch self {
        case .keyed(let table, _, _), .referencing(let table, _, _, _):
            return table
        }
    }

    var tables: Set<String> {
        switch self {
        case .keyed(let table, _, _):
            return [table]
        case .referencing(let table, _, _, let parent):
            return parent.tables.union([table])
        }
    }
}

struct CascadeDeleteRoot: Equatable, Sendable {
    let table: String
    let columns: [String]
    let primaryKeyColumns: [String]
    let rows: [[PluginCellValue]]
    let isComplete: Bool
    // Columns the same save writes in its inserts and updates, which run before the counts can see them.
    let editedColumns: Set<String>

    init(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        rows: [[PluginCellValue]],
        isComplete: Bool = true,
        editedColumns: Set<String> = []
    ) {
        self.table = table
        self.columns = columns
        self.primaryKeyColumns = primaryKeyColumns
        self.rows = rows
        self.isComplete = isComplete
        self.editedColumns = editedColumns
    }

    init?(operations: [RowWriteOperation]) {
        let deletes = operations.filter { $0.kind == .delete }
        guard let first = deletes.first else { return nil }
        self.init(
            table: first.target.table,
            columns: first.columns,
            primaryKeyColumns: first.primaryKeyColumns,
            rows: deletes.compactMap(\.preImage),
            isComplete: deletes.allSatisfy { $0.preImage != nil },
            editedColumns: Set(operations.filter { $0.kind != .delete }.flatMap(\.writtenColumns))
        )
    }

    // An edit to a key column of this table changes which rows the delete reaches.
    func editsKeyColumns(of keys: [ReferencingKey], tableNames: CascadeTableNames) -> Bool {
        let name = tableNames.key(table)
        let keyColumns = keys.flatMap { key in
            (tableNames.key(key.table) == name ? key.columns : [])
                + (tableNames.key(key.referencedTable) == name ? key.referencedColumns : [])
        }
        return !editedColumns.isDisjoint(with: keyColumns)
    }

    var primaryKeyRows: CascadeRowSet? {
        rowSet(columns: primaryKeyColumns)
    }

    // Without a primary key the referenced columns name the rows, being unique by definition.
    func rows(referencedBy key: ReferencingKey) -> CascadeRowSet? {
        primaryKeyRows ?? rowSet(columns: key.referencedColumns)
    }

    private func rowSet(columns names: [String]) -> CascadeRowSet? {
        guard isComplete, !names.isEmpty else { return nil }
        let indices = names.compactMap { columns.firstIndex(of: $0) }
        guard indices.count == names.count else { return nil }
        var seen: Set<[String]> = []
        var values: [[String]] = []
        for row in rows {
            var tuple: [String] = []
            var holdsNull = false
            for index in indices {
                guard row.indices.contains(index) else { return nil }
                switch row[index] {
                case .null: holdsNull = true
                case .text(let text): tuple.append(text)
                case .bytes: return nil
                }
            }
            // No key points at a NULL.
            guard !holdsNull, seen.insert(tuple).inserted else { continue }
            values.append(tuple)
        }
        return .keyed(table: table, columns: names, values: values)
    }
}

struct CascadeEffect: Equatable, Sendable {
    enum Kind: Hashable, Sendable {
        case delete
        case setNull(columns: [String])
        case setDefault(columns: [String])
        case block
    }

    let table: String
    let kind: Kind
    var constraints: [String]
    var paths: [CascadeRowSet]
    var hasUnexpressiblePath: Bool

    var isCountable: Bool {
        !hasUnexpressiblePath && !paths.isEmpty
    }

    fileprivate mutating func record(_ rows: CascadeRowSet?, constraint: String) {
        if !constraint.isEmpty, !constraints.contains(constraint) {
            constraints.append(constraint)
        }
        guard let rows else {
            hasUnexpressiblePath = true
            return
        }
        if !paths.contains(rows) { paths.append(rows) }
    }
}

struct CascadeDeletePlan: Equatable, Sendable {
    static let maximumDepth = 5
    // Bounds the count queries a densely linked schema can produce.
    static let maximumHops = 64

    let effects: [CascadeEffect]
    let stoppedAtDepth: Bool
    // The hop limit ran out, or a rewritten column is itself a parent key whose ON UPDATE rule the walk does not follow.
    let leftKeysUnfollowed: Bool

    private enum Origin {
        case deletedRows
        case reached(CascadeRowSet?)
    }

    private struct Node {
        let table: String
        let origin: Origin
        let depth: Int
    }

    private struct EffectID: Hashable {
        let table: String
        let kind: CascadeEffect.Kind
    }

    static func walk(
        root: CascadeDeleteRoot,
        keys: [ReferencingKey],
        tableNames: CascadeTableNames = CascadeTableNames(ignoresCase: false),
        maximumDepth: Int = maximumDepth,
        maximumHops: Int = maximumHops
    ) -> CascadeDeletePlan {
        let keysByParent = Dictionary(grouping: keys) { tableNames.key($0.referencedTable) }
        var effects: [CascadeEffect] = []
        var positions: [EffectID: Int] = [:]
        var stoppedAtDepth = false
        var leftKeysUnfollowed = false
        var hops = 0
        var queue = [Node(table: root.table, origin: .deletedRows, depth: 0)]
        var head = 0

        walk: while head < queue.count {
            let node = queue[head]
            head += 1
            for key in keysByParent[tableNames.key(node.table)] ?? [] {
                let parentRows: CascadeRowSet?
                switch node.origin {
                case .deletedRows:
                    parentRows = root.rows(referencedBy: key)
                    if case .keyed(_, _, let values)? = parentRows, values.isEmpty { continue }
                case .reached(let rows):
                    parentRows = rows
                }
                guard hops < maximumHops else {
                    leftKeysUnfollowed = true
                    break walk
                }
                hops += 1

                let childRows = parentRows.map {
                    CascadeRowSet.referencing(
                        table: key.table,
                        columns: key.columns,
                        parentColumns: key.referencedColumns,
                        parent: $0
                    )
                }
                let id = EffectID(table: key.table, kind: kind(of: key))
                if let position = positions[id] {
                    effects[position].record(childRows, constraint: key.name)
                } else {
                    positions[id] = effects.count
                    var effect = CascadeEffect(
                        table: key.table, kind: id.kind, constraints: [], paths: [], hasUnexpressiblePath: false
                    )
                    effect.record(childRows, constraint: key.name)
                    effects.append(effect)
                }

                if key.action == .setNull || key.action == .setDefault,
                   keysByParent[tableNames.key(key.table)]?.contains(where: { referencing in
                       !Set(referencing.referencedColumns).isDisjoint(with: key.columns)
                   }) == true {
                    leftKeysUnfollowed = true
                }
                guard key.action == .cascade else { continue }
                if node.depth + 1 < maximumDepth {
                    queue.append(Node(table: key.table, origin: .reached(childRows), depth: node.depth + 1))
                } else if keysByParent[tableNames.key(key.table)]?.isEmpty == false {
                    stoppedAtDepth = true
                }
            }
        }
        return CascadeDeletePlan(effects: effects, stoppedAtDepth: stoppedAtDepth, leftKeysUnfollowed: leftKeysUnfollowed)
    }

    // Rows of the effect's table the same save deletes anyway, which neither block it nor get rewritten.
    func rowsDeletedAnyway(alongside effect: CascadeEffect, root: CascadeDeleteRoot) -> [CascadeRowSet] {
        var rows: [CascadeRowSet] = []
        if effect.table == root.table, let deleted = root.primaryKeyRows {
            rows.append(deleted)
        }
        if effect.kind != .delete,
           let cascade = effects.first(where: { $0.table == effect.table && $0.kind == .delete }),
           cascade.isCountable {
            rows.append(contentsOf: cascade.paths)
        }
        return rows
    }

    private static func kind(of key: ReferencingKey) -> CascadeEffect.Kind {
        switch key.action {
        case .cascade: return .delete
        case .setNull: return .setNull(columns: key.columns)
        case .setDefault: return .setDefault(columns: key.columns)
        case .restrict, .noAction: return .block
        }
    }
}
