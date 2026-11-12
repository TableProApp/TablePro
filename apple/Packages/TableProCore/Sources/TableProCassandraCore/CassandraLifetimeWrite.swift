//
//  CassandraLifetimeWrite.swift
//  TableProCassandraCore
//

import Foundation

// A CQL write carries one TTL for all the cells it writes, so cells that keep different TTLs go in statements of
// their own, joined in one batch. The batch names one partition, so Cassandra and ScyllaDB apply it atomically.
// A cell with no TTL to keep is written without USING, as before.
public enum CassandraLifetimeWrite {
    public struct KeyCondition<Value> {
        public let cql: String
        public let values: [Value]

        public init(cql: String, values: [Value]) {
            self.cql = cql
            self.values = values
        }
    }

    public struct RowKeys<Value> {
        public let row: KeyCondition<Value>
        public let partition: KeyCondition<Value>

        public init(row: KeyCondition<Value>, partition: KeyCondition<Value>) {
            self.row = row
            self.partition = partition
        }
    }

    public struct Assignment<Value> {
        public let cql: String
        public let parameters: [Value]
        public let timeToLive: Int?
        public let isStatic: Bool

        public init(cql: String, parameters: [Value], timeToLive: Int?, isStatic: Bool) {
            self.cql = cql
            self.parameters = parameters
            self.timeToLive = timeToLive
            self.isStatic = isStatic
        }
    }

    public struct RestoredCell<Value> {
        public let column: String
        public let value: Value
        public let isKey: Bool
        public let isNull: Bool
        public let isStatic: Bool
        public let timeToLive: Int?

        public init(column: String, value: Value, isKey: Bool, isNull: Bool, isStatic: Bool, timeToLive: Int?) {
            self.column = column
            self.value = value
            self.isKey = isKey
            self.isNull = isNull
            self.isStatic = isStatic
            self.timeToLive = timeToLive
        }
    }

    public struct Statement<Value> {
        public let cql: String
        public let parameters: [Value]
    }

    // Every statement of the batch is held to the row with IF EXISTS, except one that writes only static cells
    // beside others that do not: CQL refuses clustering columns in an UPDATE of static columns alone, so that one
    // names the partition and the batch's other conditions hold it.
    public static func update<Value>(
        target: String,
        assignments: [Assignment<Value>],
        row: KeyCondition<Value>,
        partition: KeyCondition<Value>?
    ) -> Statement<Value> {
        let writesClusteringRow = assignments.contains { !$0.isStatic }
        let statements = grouped(assignments, by: \.timeToLive).map { group -> Statement<Value> in
            let set = group.items.map(\.cql)
            let parameters = group.items.flatMap(\.parameters)
            if let partition, writesClusteringRow, group.items.allSatisfy(\.isStatic) {
                return Statement(
                    cql: plainUpdate(target: target, timeToLive: group.timeToLive, set: set, key: partition.cql),
                    parameters: parameters + partition.values
                )
            }
            return Statement(
                cql: CassandraConditionalWrite.updateStatement(
                    target: target, assignments: set, keyCondition: row.cql, timeToLive: group.timeToLive
                ),
                parameters: parameters + row.values
            )
        }
        return batched(statements)
    }

    // The INSERT carries the key and also writes the row marker, so it takes the cells that live longest: those
    // that never expire, then those left to the table's default, then the longest TTL. The rest are UPDATEs.
    public static func restore<Value>(
        target: String,
        cells: [RestoredCell<Value>],
        keys: RowKeys<Value>?
    ) -> Statement<Value> {
        let valued = cells.filter { !$0.isKey && !$0.isNull }
        guard let keys, valued.contains(where: { $0.timeToLive != nil }) else {
            return insert(target: target, cells: cells, timeToLive: nil)
        }
        let groups = grouped(valued, by: \.timeToLive)
        let inserted = longestLiving(groups.map { $0.timeToLive })
        let insertion = insert(
            target: target,
            cells: cells.filter { $0.isKey || $0.isNull || $0.timeToLive == inserted },
            timeToLive: inserted
        )
        let updates = groups.filter { $0.timeToLive != inserted }.map { group -> Statement<Value> in
            let key = group.items.allSatisfy(\.isStatic) ? keys.partition : keys.row
            let set = group.items.map { "\(CassandraObjectQueries.quote($0.column)) = ?" }
            return Statement(
                cql: plainUpdate(target: target, timeToLive: group.timeToLive, set: set, key: key.cql),
                parameters: group.items.map(\.value) + key.values
            )
        }
        return batched([insertion] + updates)
    }

    static func longestLiving(_ timesToLive: [Int?]) -> Int? {
        if timesToLive.contains(0) { return 0 }
        if timesToLive.contains(where: { $0 == nil }) { return nil }
        return timesToLive.compactMap { $0 }.max()
    }

    private static func grouped<Item>(
        _ items: [Item],
        by timeToLive: (Item) -> Int?
    ) -> [(timeToLive: Int?, items: [Item])] {
        var groups: [(timeToLive: Int?, items: [Item])] = []
        for item in items {
            let key = timeToLive(item)
            if let index = groups.firstIndex(where: { $0.timeToLive == key }) {
                groups[index].items.append(item)
            } else {
                groups.append((key, [item]))
            }
        }
        return groups
    }

    private static func insert<Value>(
        target: String,
        cells: [RestoredCell<Value>],
        timeToLive: Int?
    ) -> Statement<Value> {
        let names = cells.map { CassandraObjectQueries.quote($0.column) }.joined(separator: ", ")
        let markers = Array(repeating: "?", count: cells.count).joined(separator: ", ")
        return Statement(
            cql: "INSERT INTO \(target) (\(names)) VALUES (\(markers))"
                + CassandraConditionalWrite.usingClause(timeToLive: timeToLive),
            parameters: cells.map(\.value)
        )
    }

    private static func plainUpdate(target: String, timeToLive: Int?, set: [String], key: String) -> String {
        "UPDATE \(target)\(CassandraConditionalWrite.usingClause(timeToLive: timeToLive)) SET "
            + "\(set.joined(separator: ", ")) WHERE \(key)"
    }

    private static func batched<Value>(_ statements: [Statement<Value>]) -> Statement<Value> {
        if statements.count == 1, let only = statements.first { return only }
        return Statement(
            cql: CassandraConditionalWrite.batch(statements.map(\.cql)),
            parameters: statements.flatMap(\.parameters)
        )
    }
}

extension CassandraLifetimeWrite.KeyCondition: Sendable where Value: Sendable {}
extension CassandraLifetimeWrite.RowKeys: Sendable where Value: Sendable {}
extension CassandraLifetimeWrite.Assignment: Sendable where Value: Sendable {}
extension CassandraLifetimeWrite.RestoredCell: Sendable where Value: Sendable {}
extension CassandraLifetimeWrite.Statement: Sendable where Value: Sendable {}
