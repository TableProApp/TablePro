//
//  CassandraTableLayout.swift
//  TableProCassandraCore
//

import Foundation

// What system_schema says about a table's columns: which ones a browse can read a TTL() for, and how an edit names
// the row or, for static columns, the partition.
public struct CassandraTableLayout: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case partitionKey = "partition_key"
        case clustering
        case staticColumn = "static"
        case regular
    }

    public struct Column: Sendable, Equatable {
        public let name: String
        public let type: String
        public let kind: Kind
        public let position: Int

        public init(name: String, type: String, kind: Kind, position: Int) {
            self.name = name
            self.type = type
            self.kind = kind
            self.position = position
        }
    }

    public let partitionKey: [String]
    public let clustering: [String]
    public let staticColumns: Set<String>
    public let selectOrder: [String]
    // Nil when the table's options could not be read.
    public let defaultTimeToLive: Int?
    private let lifetimeColumns: Set<String>

    // CQL3Type.Native without counter and empty: each holds one cell.
    private static let singleCellTypes: Set<String> = [
        "ascii", "bigint", "blob", "boolean", "date", "decimal", "double", "duration", "float", "inet", "int",
        "smallint", "text", "time", "timestamp", "timeuuid", "tinyint", "uuid", "varchar", "varint",
    ]
    private static let singleCellPrefixes = ["frozen<", "tuple<", "vector<"]

    // Nil for a table system_schema lists no columns for, such as a virtual table, and for a COMPACT STORAGE table,
    // whose `empty` value column `SELECT *` leaves out.
    public init?(columns: [Column], defaultTimeToLive: Int?) {
        guard !columns.isEmpty, !columns.contains(where: { Self.normalized($0.type) == "empty" }) else { return nil }
        let byPosition = { (kind: Kind) in
            columns.filter { $0.kind == kind }.sorted { $0.position < $1.position }.map(\.name)
        }
        let byName = { (kind: Kind) in
            columns.filter { $0.kind == kind }.map(\.name).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        }
        partitionKey = byPosition(.partitionKey)
        clustering = byPosition(.clustering)
        let statics = byName(.staticColumn)
        staticColumns = Set(statics)
        // Cassandra's allColumnsInSelectOrder: the key in order, then static and regular columns by name.
        selectOrder = partitionKey + clustering + statics + byName(.regular)
        self.defaultTimeToLive = defaultTimeToLive
        lifetimeColumns = Set(columns.filter { column in
            (column.kind == .regular || column.kind == .staticColumn) && Self.holdsOneCell(column.type)
        }.map(\.name))
    }

    public var primaryKey: [String] { partitionKey + clustering }

    // TTL() refuses a key column, and before Cassandra 5.0 a non-frozen collection or user type. A counter has no
    // TTL, and an UPDATE of one refuses USING TTL.
    public func acceptsTimeToLive(_ column: String) -> Bool {
        lifetimeColumns.contains(column)
    }

    public static func columnsQuery(keyspace: String, table: String) -> String {
        """
        SELECT column_name, type, kind, position FROM system_schema.columns
        WHERE keyspace_name = '\(CassandraObjectQueries.escapeLiteral(keyspace))'
          AND table_name = '\(CassandraObjectQueries.escapeLiteral(table))'
        """
    }

    public static func defaultTimeToLiveQuery(keyspace: String, table: String) -> String {
        """
        SELECT default_time_to_live FROM system_schema.tables
        WHERE keyspace_name = '\(CassandraObjectQueries.escapeLiteral(keyspace))'
          AND table_name = '\(CassandraObjectQueries.escapeLiteral(table))'
        """
    }

    // One row of `columnsQuery`, nil when a part is missing or the kind is not one CQL has.
    public static func column(name: String?, type: String?, kind: String?, position: String?) -> Column? {
        guard let name, let type, let kind = kind.flatMap(Kind.init(rawValue:)) else { return nil }
        return Column(name: name, type: type, kind: kind, position: position.flatMap { Int($0) } ?? 0)
    }

    private static func holdsOneCell(_ type: String) -> Bool {
        let type = normalized(type)
        return singleCellTypes.contains(type) || singleCellPrefixes.contains { type.hasPrefix($0) }
    }

    private static func normalized(_ type: String) -> String {
        type.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
