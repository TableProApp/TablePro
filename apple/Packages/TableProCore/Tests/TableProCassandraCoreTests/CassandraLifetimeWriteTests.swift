//
//  CassandraLifetimeWriteTests.swift
//  TableProCassandraCoreTests
//

import TableProCassandraCore
import Testing

struct CassandraLifetimeWriteTests {
    private typealias Write = CassandraLifetimeWrite
    private static let target = "\"shop\".\"visits\""
    private static let row = Write.KeyCondition(cql: "\"id\" = ? AND \"day\" = ?", values: ["k", "d"])
    private static let partition = Write.KeyCondition(cql: "\"id\" = ?", values: ["k"])

    private static func set(_ column: String, _ value: String, ttl: Int?, isStatic: Bool = false) -> Write.Assignment<String> {
        Write.Assignment(cql: "\"\(column)\" = ?", parameters: [value], timeToLive: ttl, isStatic: isStatic)
    }

    @Test("An edit with no TTL to keep is the statement it always was")
    func noTimeToLive() {
        let write = Write.update(
            target: Self.target, assignments: [Self.set("note", "n", ttl: nil)], row: Self.row, partition: Self.partition
        )
        #expect(write.cql == CassandraConditionalWrite.updateStatement(
            target: Self.target, assignments: ["\"note\" = ?"], keyCondition: Self.row.cql
        ))
        #expect(write.parameters == ["n", "k", "d"])
    }

    @Test("Cells that keep one TTL are one UPDATE with it")
    func oneTimeToLive() {
        let write = Write.update(
            target: Self.target,
            assignments: [Self.set("note", "n", ttl: 120), Self.set("address", "a", ttl: 120)],
            row: Self.row,
            partition: Self.partition
        )
        #expect(write.cql == "UPDATE \"shop\".\"visits\" USING TTL 120 SET \"note\" = ?, \"address\" = ? "
            + "WHERE \"id\" = ? AND \"day\" = ? IF EXISTS")
        #expect(write.parameters == ["n", "a", "k", "d"])
    }

    @Test("Cells that keep different TTLs are one batch on the row, a static-only UPDATE naming the partition")
    func severalTimesToLive() {
        let write = Write.update(
            target: Self.target,
            assignments: [
                Self.set("note", "n", ttl: 120),
                Self.set("address", "a", ttl: 0),
                Self.set("Count", "c", ttl: nil),
                Self.set("owner", "o", ttl: 50, isStatic: true),
                Self.set("extra", "e", ttl: 120),
            ],
            row: Self.row,
            partition: Self.partition
        )
        #expect(write.cql == "BEGIN BATCH "
            + "UPDATE \"shop\".\"visits\" USING TTL 120 SET \"note\" = ?, \"extra\" = ? WHERE \"id\" = ? AND \"day\" = ? IF EXISTS; "
            + "UPDATE \"shop\".\"visits\" USING TTL 0 SET \"address\" = ? WHERE \"id\" = ? AND \"day\" = ? IF EXISTS; "
            + "UPDATE \"shop\".\"visits\" SET \"Count\" = ? WHERE \"id\" = ? AND \"day\" = ? IF EXISTS; "
            + "UPDATE \"shop\".\"visits\" USING TTL 50 SET \"owner\" = ? WHERE \"id\" = ?; "
            + "APPLY BATCH")
        #expect(write.parameters == ["n", "e", "k", "d", "a", "k", "d", "c", "k", "d", "o", "k"])
        #expect(CassandraConditionalWrite.refusal(statement: write.cql, firstColumn: "[applied]", firstValue: "false")
            == .rowMissing)
    }

    private static func cell(
        _ column: String,
        ttl: Int? = nil,
        isKey: Bool = false,
        isNull: Bool = false,
        isStatic: Bool = false
    ) -> Write.RestoredCell<String> {
        Write.RestoredCell(
            column: column, value: column, isKey: isKey, isNull: isNull, isStatic: isStatic, timeToLive: ttl
        )
    }

    private static let keys = Write.RowKeys(row: row, partition: partition)

    @Test("A restored row with no TTL to keep is the INSERT it always was")
    func restoreWithoutTimesToLive() {
        let cells = [Self.cell("id", isKey: true), Self.cell("day", isKey: true), Self.cell("note"), Self.cell("Count", isNull: true)]
        let expected = "INSERT INTO \"shop\".\"visits\" (\"id\", \"day\", \"note\", \"Count\") VALUES (?, ?, ?, ?)"
        for keys in [nil, Self.keys] {
            let write = Write.restore(target: Self.target, cells: cells, keys: keys)
            #expect(write.cql == expected)
            #expect(write.parameters == ["id", "day", "note", "Count"])
        }
        let unkeyed = Write.restore(
            target: Self.target, cells: [Self.cell("id", isKey: true), Self.cell("note", ttl: 40)], keys: nil
        )
        #expect(unkeyed.cql == "INSERT INTO \"shop\".\"visits\" (\"id\", \"note\") VALUES (?, ?)")
    }

    @Test("A restored row whose cells share a TTL is one INSERT with it")
    func restoreOneTimeToLive() {
        let write = Write.restore(
            target: Self.target,
            cells: [Self.cell("id", isKey: true), Self.cell("day", isKey: true), Self.cell("note", ttl: 90),
                    Self.cell("Count", isNull: true), Self.cell("owner", ttl: 90, isStatic: true)],
            keys: Self.keys
        )
        #expect(write.cql == "INSERT INTO \"shop\".\"visits\" (\"id\", \"day\", \"note\", \"Count\", \"owner\") "
            + "VALUES (?, ?, ?, ?, ?) USING TTL 90")
        #expect(write.parameters == ["id", "day", "note", "Count", "owner"])
    }

    // The INSERT also writes the row marker, so it takes the cells that live longest.
    @Test("A restored row with several TTLs is a batch whose INSERT carries the longest-living cells")
    func restoreSeveralTimesToLive() {
        let write = Write.restore(
            target: Self.target,
            cells: [
                Self.cell("id", isKey: true), Self.cell("day", isKey: true),
                Self.cell("owner", ttl: 50, isStatic: true), Self.cell("note", ttl: 120),
                Self.cell("address", ttl: 0), Self.cell("Count", isNull: true), Self.cell("tags"),
            ],
            keys: Self.keys
        )
        #expect(write.cql == "BEGIN BATCH "
            + "INSERT INTO \"shop\".\"visits\" (\"id\", \"day\", \"address\", \"Count\") VALUES (?, ?, ?, ?) USING TTL 0; "
            + "UPDATE \"shop\".\"visits\" USING TTL 50 SET \"owner\" = ? WHERE \"id\" = ?; "
            + "UPDATE \"shop\".\"visits\" USING TTL 120 SET \"note\" = ? WHERE \"id\" = ? AND \"day\" = ?; "
            + "UPDATE \"shop\".\"visits\" SET \"tags\" = ? WHERE \"id\" = ? AND \"day\" = ?; "
            + "APPLY BATCH")
        #expect(write.parameters == [
            "id", "day", "address", "Count", "owner", "k", "note", "k", "d", "tags", "k", "d",
        ])
        #expect(CassandraConditionalWrite.refusal(statement: write.cql, firstColumn: "[applied]", firstValue: "false")
            == nil)
    }

    @Test("Without a cell that never expires, the INSERT takes the table's default, else the longest TTL")
    func restoreInsertChoice() {
        let base = [Self.cell("id", isKey: true), Self.cell("day", isKey: true)]
        let toDefault = Write.restore(
            target: Self.target, cells: base + [Self.cell("note", ttl: 30), Self.cell("tags")], keys: Self.keys
        )
        #expect(toDefault.cql.hasPrefix("BEGIN BATCH INSERT INTO \"shop\".\"visits\" (\"id\", \"day\", \"tags\") VALUES (?, ?, ?); "))
        let longest = Write.restore(
            target: Self.target, cells: base + [Self.cell("note", ttl: 30), Self.cell("address", ttl: 900)], keys: Self.keys
        )
        #expect(longest.cql.hasPrefix(
            "BEGIN BATCH INSERT INTO \"shop\".\"visits\" (\"id\", \"day\", \"address\") VALUES (?, ?, ?) USING TTL 900; "
        ))
        #expect(longest.cql.contains("UPDATE \"shop\".\"visits\" USING TTL 30 SET \"note\" = ? WHERE \"id\" = ? AND \"day\" = ?; "))
    }
}
