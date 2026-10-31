//
//  MySQLTableHealthProviderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct MySQLTableHealthProviderTests {
    private let provider = MySQLTableHealthProvider()

    private typealias IndexRow = (index: String, nonUnique: String, type: String, column: String?, subPart: String?)

    private static let indexColumns = [
        "schema_name", "table_name", "index_name", "non_unique", "index_type", "column_name", "sub_part", "sort_order"
    ]

    private func redundant(in rows: [IndexRow], table: String = "orders", sortOrders: [String?]? = nil) -> [String: String] {
        let result = TableHealthFixture.result(
            columns: Self.indexColumns,
            rows: rows.enumerated().map { position, row -> [String?] in
                let sortOrder = sortOrders?[position] ?? (row.type == "BTREE" ? "A" : nil)
                return ["shop", table, row.index, row.nonUnique, row.type, row.column, row.subPart, sortOrder]
            }
        )
        var map: [String: String] = [:]
        for finding in provider.findings(for: .redundantIndex, from: result) {
            map[finding.objectName ?? ""] = finding.detail
        }
        return map
    }

    @Test("An index whose columns lead another index is redundant to it")
    func prefixIsRedundant() {
        let found = redundant(in: [
            ("PRIMARY", "0", "BTREE", "id", nil),
            ("idx_a", "1", "BTREE", "a", nil),
            ("idx_ab", "1", "BTREE", "a", nil),
            ("idx_ab", "1", "BTREE", "b", nil),
            ("uniq_b", "0", "BTREE", "b", nil)
        ])
        #expect(Array(found.keys) == ["idx_a"])
        #expect(found["idx_a"]?.contains("idx_ab") == true)
    }

    @Test("A shorter unique index enforces more than the longer one, so it stays")
    func shorterUniqueStays() {
        let found = redundant(in: [
            ("uniq_a", "0", "BTREE", "a", nil),
            ("idx_ab", "1", "BTREE", "a", nil),
            ("idx_ab", "1", "BTREE", "b", nil)
        ])
        #expect(found.isEmpty)
    }

    @Test("Of two equal plain indexes, the one later by name is redundant")
    func equalPlainIndexes() {
        let found = redundant(in: [
            ("idx_x", "1", "BTREE", "a", nil),
            ("idx_y", "1", "BTREE", "a", nil)
        ])
        #expect(Array(found.keys) == ["idx_y"])
    }

    @Test("A plain index equal to a unique one is redundant to it")
    func plainEqualToUnique() {
        let found = redundant(in: [
            ("a_plain", "1", "BTREE", "a", nil),
            ("z_unique", "0", "BTREE", "a", nil)
        ])
        #expect(Array(found.keys) == ["a_plain"])
    }

    @Test("A unique index equal to the primary key is redundant, and the primary key never is")
    func uniqueEqualToPrimary() {
        let found = redundant(in: [
            ("PRIMARY", "0", "BTREE", "id", nil),
            ("id_unique", "0", "BTREE", "id", nil)
        ])
        #expect(Array(found.keys) == ["id_unique"])
    }

    @Test("A column prefix length, an expression or another index type keeps an index apart")
    func shapesThatDoNotCompare() {
        let found = redundant(in: [
            ("idx_a10", "1", "BTREE", "a", "10"),
            ("idx_ab", "1", "BTREE", "a", nil),
            ("idx_ab", "1", "BTREE", "b", nil),
            ("idx_expr", "1", "BTREE", nil, nil),
            ("idx_expr", "1", "BTREE", "b", nil),
            ("ft_a", "1", "FULLTEXT", "a", nil)
        ])
        #expect(found.isEmpty)
    }

    @Test("A full-text index is redundant only to an identical one, never to a longer one")
    func fullTextNeedsExactColumns() {
        let prefix = redundant(in: [
            ("ft_a", "1", "FULLTEXT", "a", nil),
            ("ft_ab", "1", "FULLTEXT", "a", nil),
            ("ft_ab", "1", "FULLTEXT", "b", nil)
        ])
        let identical = redundant(in: [
            ("ft_a", "1", "FULLTEXT", "a", nil),
            ("ft_a2", "1", "FULLTEXT", "a", nil)
        ])
        #expect(prefix.isEmpty)
        #expect(Array(identical.keys) == ["ft_a2"])
    }

    @Test("A key part sorted the other way keeps an index apart")
    func sortDirectionMatters() {
        let found = redundant(
            in: [
                ("idx_ab_desc", "1", "BTREE", "a", nil),
                ("idx_ab_desc", "1", "BTREE", "b", nil),
                ("idx_ab", "1", "BTREE", "a", nil),
                ("idx_ab", "1", "BTREE", "b", nil)
            ],
            sortOrders: ["A", "D", "A", "A"]
        )
        #expect(found.isEmpty)
    }

    @Test("Indexes compare only within their own table")
    func tablesStayApart() {
        let result = TableHealthFixture.result(
            columns: Self.indexColumns,
            rows: [
                ["shop", "a", "idx_x", "1", "BTREE", "c", nil, "A"],
                ["shop", "b", "idx_xy", "1", "BTREE", "c", nil, "A"],
                ["shop", "b", "idx_xy", "1", "BTREE", "d", nil, "A"]
            ]
        )
        #expect(provider.findings(for: .redundantIndex, from: result).isEmpty)
    }

    @Test("A redundant index previews a drop with backtick quoting")
    func redundantFixQuotes() throws {
        let result = TableHealthFixture.result(
            columns: Self.indexColumns,
            rows: [
                ["shop", "odd`name", "idx_a", "1", "BTREE", "a", nil, "A"],
                ["shop", "odd`name", "idx_ab", "1", "BTREE", "a", nil, "A"],
                ["shop", "odd`name", "idx_ab", "1", "BTREE", "b", nil, "A"]
            ]
        )
        let finding = try #require(provider.findings(for: .redundantIndex, from: result).first)
        #expect(finding.fixSQL == "ALTER TABLE `shop`.`odd``name` DROP INDEX `idx_a`;")
    }

    @Test("An unused index and a table without a primary key preview their fixes")
    func unusedAndMissingKeyFixes() throws {
        let unused = TableHealthFixture.result(
            columns: ["schema_name", "table_name", "index_name"],
            rows: [["shop", "orders", "orders_note_idx"]]
        )
        let noKey = TableHealthFixture.result(columns: ["schema_name", "table_name"], rows: [["shop", "logs"]])

        let unusedFinding = try #require(provider.findings(for: .unusedIndex, from: unused).first)
        let keyFinding = try #require(provider.findings(for: .missingPrimaryKey, from: noKey).first)

        #expect(unusedFinding.fixSQL == "ALTER TABLE `shop`.`orders` DROP INDEX `orders_note_idx`;")
        #expect(keyFinding.fixSQL == "ALTER TABLE `shop`.`logs` ADD PRIMARY KEY (column_name);")
        #expect(provider.schemaNamesDatabase)
    }

    @Test("With Performance Schema off, the note says no index usage is recorded")
    func performanceSchemaOff() {
        let off = TableHealthFixture.result(columns: ["performance_schema"], rows: [["0"]])
        let uptime = TableHealthFixture.result(columns: ["Variable_name", "Value"], rows: [["Uptime", "3600"]])
        #expect(provider.statisticsNote(from: [off, uptime], now: Date())?.contains("Performance Schema is off") == true)
    }

    @Test("With Performance Schema on, the note names the server start")
    func serverStartNote() {
        let on = TableHealthFixture.result(columns: ["performance_schema"], rows: [["1"]])
        let uptime = TableHealthFixture.result(columns: ["Variable_name", "Value"], rows: [["Uptime", "3600"]])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = Date(timeIntervalSince1970: 1_800_000_000 - 3600).formatted(date: .abbreviated, time: .shortened)

        #expect(provider.statisticsNote(from: [on, uptime], now: now)?.contains(start) == true)
    }

    @Test("Every query the report runs only reads")
    func queriesOnlyRead() {
        for check in provider.checks {
            let query = provider.query(for: check).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(query.uppercased().hasPrefix("SELECT"), "\(check) does not start with SELECT")
        }
        #expect(MySQLTableHealthProvider.uptimeQuery.hasPrefix("SHOW "))
    }
}
