import Foundation

// One foreign key, its column pairs in key order.
public struct SQLCompletionForeignKey: Sendable, Hashable {
    public let name: String
    public let columns: [String]
    public let referencedTable: String
    public let referencedSchema: String?
    public let referencedColumns: [String]

    public init(
        name: String,
        columns: [String],
        referencedTable: String,
        referencedSchema: String? = nil,
        referencedColumns: [String]
    ) {
        self.name = name
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedSchema = referencedSchema
        self.referencedColumns = referencedColumns
    }

    // A driver reports one row per column pair.
    public struct Row: Sendable {
        public let name: String
        public let column: String
        public let referencedTable: String
        public let referencedSchema: String?
        public let referencedColumn: String

        public init(name: String, column: String, referencedTable: String, referencedSchema: String?, referencedColumn: String) {
            self.name = name
            self.column = column
            self.referencedTable = referencedTable
            self.referencedSchema = referencedSchema
            self.referencedColumn = referencedColumn
        }
    }

    // A composite key's rows share its name and target. Keys keep the order the driver read them in.
    public static func grouping(_ rows: [Row]) -> [SQLCompletionForeignKey] {
        struct Identity: Hashable {
            let name: String
            let table: String
            let schema: String?
        }
        var order: [Identity] = []
        var pairs: [Identity: [(column: String, referenced: String)]] = [:]
        for row in rows {
            let identity = Identity(name: row.name, table: row.referencedTable, schema: row.referencedSchema)
            if pairs[identity] == nil { order.append(identity) }
            let pair = (column: row.column, referenced: row.referencedColumn)
            guard pairs[identity]?.contains(where: { $0 == pair }) != true else { continue }
            pairs[identity, default: []].append(pair)
        }
        return order.map { identity in
            let keyPairs = pairs[identity] ?? []
            return SQLCompletionForeignKey(
                name: identity.name,
                columns: keyPairs.map { $0.column },
                referencedTable: identity.table,
                referencedSchema: identity.schema,
                referencedColumns: keyPairs.map { $0.referenced }
            )
        }
    }
}

// The table whose ON the cursor follows, and the tables that ON may name, nearest first.
public struct SQLJoinScope: Sendable, Equatable {
    public let joined: TableReference
    public let earlier: [TableReference]

    public init(joined: TableReference, earlier: [TableReference]) {
        self.joined = joined
        self.earlier = earlier
    }

    // Only a stored table has foreign keys, so a CTE or a derived table on either side is left out.
    init?(
        _ found: (joined: DerivedTableParser.JoinSource, earlier: [DerivedTableParser.JoinSource]),
        references: [TableReference],
        cteNames: [String]
    ) {
        func stored(_ source: DerivedTableParser.JoinSource) -> TableReference? {
            if source.schema == nil, cteNames.contains(where: { $0.caseInsensitiveCompare(source.table) == .orderedSame }) {
                return nil
            }
            let reference = references.first {
                $0.tableName == source.table && $0.alias == source.alias && $0.schema == source.schema
            } ?? TableReference(
                tableName: source.table, alias: source.alias, schema: source.schema, isIdentifierQuoted: source.isQuoted
            )
            return reference.isDerived ? nil : reference
        }
        guard let joined = stored(found.joined) else { return nil }
        let earlier = found.earlier.compactMap(stored)
        guard !earlier.isEmpty else { return nil }
        self.init(joined: joined, earlier: earlier)
    }
}

enum SQLJoinConditions {
    struct Side {
        let reference: TableReference
        let keys: [SQLCompletionForeignKey]
        let columns: [String]
    }

    struct ColumnPair: Equatable {
        let earlier: String
        let joined: String
    }

    struct Condition: Equatable {
        let earlier: TableReference
        let constraintName: String
        let columns: [ColumnPair]
    }

    // Per earlier table, nearest first: its keys to the joined table, then the joined table's keys to it. The earlier
    // table's column goes first either way, and a self-join yields both orientations.
    static func conditions(joined: Side, earlier: [Side]) -> [Condition] {
        earlier.flatMap { side -> [Condition] in
            let outgoing = side.keys.filter { targets($0, from: side.reference, joined.reference) }.map { key in
                Condition(earlier: side.reference, constraintName: key.name, columns: zip(key.columns, key.referencedColumns).map {
                    ColumnPair(earlier: spelling($0.0, in: side.columns), joined: spelling($0.1, in: joined.columns))
                })
            }
            let incoming = joined.keys.filter { targets($0, from: joined.reference, side.reference) }.map { key in
                Condition(earlier: side.reference, constraintName: key.name, columns: zip(key.columns, key.referencedColumns).map {
                    ColumnPair(earlier: spelling($0.1, in: side.columns), joined: spelling($0.0, in: joined.columns))
                })
            }
            return outgoing + incoming
        }
    }

    // A key with no target schema points into its own table's namespace. The catalog keeps only keys that stay in the
    // namespace they were read in, so with the owner unqualified a key reaches the unqualified tables, and with the
    // owner qualified it reaches only tables qualified the same way.
    private static func targets(
        _ key: SQLCompletionForeignKey,
        from owner: TableReference,
        _ reference: TableReference
    ) -> Bool {
        guard key.referencedTable.caseInsensitiveCompare(reference.tableName) == .orderedSame,
              !key.columns.isEmpty, key.columns.count == key.referencedColumns.count else { return false }
        switch (key.referencedSchema ?? owner.schema, reference.schema) {
        case (nil, nil):
            return true
        case let (keySchema?, schema?):
            return keySchema.caseInsensitiveCompare(schema) == .orderedSame
        case (.some, nil):
            return owner.schema == nil
        case (nil, .some):
            return false
        }
    }

    // SQLite reports a key's columns as its REFERENCES clause spells them, which may differ in case from the table's.
    private static func spelling(_ column: String, in columns: [String]) -> String {
        guard !columns.contains(column) else { return column }
        let matches = columns.filter { $0.caseInsensitiveCompare(column) == .orderedSame }
        return matches.count == 1 ? matches[0] : column
    }
}
