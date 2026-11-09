import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// The cases a PostgreSQL 13 and 17 server gave for the redundant index rule; the probe seeds the same names.
struct PostgreSQLIndexShapeTests {
    private struct Key: ExpressibleByStringLiteral {
        let column: String
        var opclass = "1978"
        var collation = "0"
        var sort = "0"

        init(_ column: String, opclass: String = "1978", collation: String = "0", sort: String = "0") {
            self.column = column
            self.opclass = opclass
            self.collation = collation
            self.sort = sort
        }

        init(stringLiteral value: String) {
            self.init(value)
        }
    }

    private struct IndexRow {
        var schema = "public"
        var table = "ri"
        var tableKind = "r"
        let name: String
        var method = "btree"
        var unique = false
        var primary = false
        var immediate = true
        var nullsNotDistinct = false
        var protected = false
        var predicate: String?
        var bytes = "8192"
        let keys: [Key]
        var includes: [String] = []
    }

    private static let columns = [
        "schema_name", "table_name", "table_kind", "index_name", "access_method", "is_unique", "is_primary", "is_immediate",
        "nulls_not_distinct", "is_protected", "predicate", "index_bytes", "index_definition", "key_count", "position",
        "column_text", "opclass", "collation", "sort_option"
    ]

    private static func flag(_ value: Bool) -> String { value ? "t" : "f" }

    private static func rows(_ indexes: [IndexRow]) -> [[String?]] {
        indexes.flatMap { index -> [[String?]] in
            var parts: [(column: String, key: Key?)] = []
            for key in index.keys {
                parts.append((key.column, key))
            }
            for column in index.includes {
                parts.append((column, nil))
            }
            return parts.enumerated().map { offset, part -> [String?] in
                [
                    index.schema, index.table, index.tableKind, index.name, index.method, flag(index.unique), flag(index.primary),
                    flag(index.immediate), index.nullsNotDistinct ? "true" : "false", flag(index.protected), index.predicate,
                    index.bytes, offset == 0 ? "CREATE INDEX \(index.name) ON \(index.schema).\(index.table)" : nil,
                    String(index.keys.count), String(offset + 1), part.column, part.key?.opclass, part.key?.collation,
                    part.key?.sort
                ]
            }
        }
    }

    private let provider = PostgreSQLTableHealthProvider()

    private func findings(_ indexes: [IndexRow]) -> [TableHealthFinding] {
        findings(rows: Self.rows(indexes))
    }

    private func findings(rows: [[String?]]) -> [TableHealthFinding] {
        provider.findings(
            for: .redundantIndex,
            from: [TableHealthFixture.result(columns: Self.columns, rows: rows)],
            context: TableHealthFixture.postgresContext(),
            statistics: TableHealthStatistics()
        ).findings
    }

    // Redundant index name to the covering index the finding names.
    private func redundant(_ indexes: [IndexRow]) -> [String: String] {
        var map: [String: String] = [:]
        for finding in findings(indexes) {
            if case .text(let covering)? = finding.metric("covering_index")?.value {
                map[finding.objectName ?? ""] = covering
            }
        }
        return map
    }

    @Test("An index whose keys lead another B-tree index is redundant to it, and of an equal pair the later name goes")
    func prefixAndDuplicate() {
        let found = redundant([
            IndexRow(name: "ri_pkey", primary: true, protected: true, keys: ["id"]),
            IndexRow(name: "r_a", keys: ["a"]),
            IndexRow(name: "k_ab", keys: ["a", "b"]),
            IndexRow(name: "r_ab_dup", keys: ["a", "b"])
        ])
        #expect(found == ["r_a": "k_ab", "r_ab_dup": "k_ab"])
    }

    @Test("Sort order, key order, operator class, collation, access method and expression keep indexes apart")
    func keyPartsKeepIndexesApart() {
        let found = redundant([
            IndexRow(name: "k_ab", keys: ["a", "b"]),
            IndexRow(name: "k_a_desc", keys: [Key("a", sort: "3")]),
            IndexRow(name: "k_ba", keys: ["b", "a"]),
            IndexRow(name: "k_code", keys: [Key("code", opclass: "3126", collation: "100")]),
            IndexRow(name: "k_code_pattern", keys: [Key("code", opclass: "4217", collation: "100")]),
            IndexRow(name: "k_code_c", keys: [Key("code", opclass: "3126", collation: "950")]),
            IndexRow(name: "k_hash_a", method: "hash", keys: [Key("a", opclass: "10020")]),
            IndexRow(name: "k_lower_email", keys: [Key("lower(email)", opclass: "3126", collation: "100")]),
            IndexRow(name: "k_upper_email", keys: [Key("upper(email)", opclass: "3126", collation: "100")])
        ])
        #expect(found.isEmpty)
    }

    @Test("The same expression twice is a duplicate")
    func duplicateExpression() {
        let found = redundant([
            IndexRow(name: "k_lower_email", keys: [Key("lower(email)", opclass: "3126", collation: "100")]),
            IndexRow(name: "r_lower_email_dup", keys: [Key("lower(email)", opclass: "3126", collation: "100")])
        ])
        #expect(found == ["r_lower_email_dup": "k_lower_email"])
    }

    @Test("A partial index is covered only by one with the same predicate")
    func partialNeedsSamePredicate() {
        let found = redundant([
            IndexRow(name: "k_ab", keys: ["a", "b"]),
            IndexRow(name: "k_a_partial", predicate: "(a > 0)", keys: ["a"]),
            IndexRow(name: "k_a_partial_twin_b", predicate: "(a > 0)", keys: ["a", "b"]),
            IndexRow(name: "r_a_partial_dup", predicate: "(a > 0)", keys: ["a"])
        ])
        #expect(found == ["k_a_partial": "k_a_partial_twin_b", "r_a_partial_dup": "k_a_partial_twin_b"])
    }

    @Test("A plain index is covered by a unique one, but a unique index never by a longer one")
    func uniqueNeedsSameKeys() {
        let found = redundant([
            IndexRow(name: "k_uniq_c", unique: true, keys: ["c"]),
            IndexRow(name: "k_cb", keys: ["c", "b"]),
            IndexRow(name: "r_c_plain", keys: ["c"])
        ])
        #expect(found == ["r_c_plain": "k_uniq_c"])
    }

    @Test("A unique index equal to the primary key is redundant, and the primary key never is")
    func uniqueEqualToPrimaryKey() {
        let found = redundant([
            IndexRow(name: "a_id_uniq", unique: true, keys: ["id"]),
            IndexRow(name: "ri_pkey", unique: true, primary: true, protected: true, keys: ["id"])
        ])
        #expect(found == ["a_id_uniq": "ri_pkey"])
    }

    @Test("A deferrable unique constraint and an immediate unique index enforce different rules")
    func deferrableIsNotImmediate() {
        let found = redundant([
            IndexRow(table: "rd", name: "k_rd_v_deferrable", unique: true, immediate: false, protected: true, keys: ["v"]),
            IndexRow(table: "rd", name: "k_rd_v_immediate", unique: true, keys: ["v"])
        ])
        #expect(found.isEmpty)
    }

    @Test("NULLS NOT DISTINCT is a different rule, and a plain index names the first unique one")
    func nullsNotDistinct() {
        let found = redundant([
            IndexRow(name: "k_nd", unique: true, keys: ["b"]),
            IndexRow(name: "k_nnd", unique: true, nullsNotDistinct: true, keys: ["b"]),
            IndexRow(name: "r_b_plain", keys: ["b"])
        ])
        #expect(found == ["r_b_plain": "k_nd"])
    }

    @Test("Constraint, partition and replica identity indexes stay, and a duplicate of one goes whatever its name")
    func protectedIndexesStay() {
        let found = redundant([
            IndexRow(table: "rc", name: "k_rc_x_key", unique: true, protected: true, keys: ["x"]),
            IndexRow(table: "rc", name: "a_rc_x_uidx", unique: true, keys: ["x"]),
            IndexRow(table: "rc", name: "r_rc_x_plain", keys: ["x"]),
            IndexRow(table: "rk", name: "z_rk_z_fkref", unique: true, protected: true, keys: ["z"]),
            IndexRow(table: "rk", name: "a_rk_z_twin", unique: true, keys: ["z"]),
            IndexRow(table: "rr", name: "a_replica", unique: true, protected: true, keys: ["k"]),
            IndexRow(table: "rr", name: "b_replica_twin", unique: true, protected: true, keys: ["k"])
        ])
        #expect(found == ["a_rc_x_uidx": "k_rc_x_key", "r_rc_x_plain": "k_rc_x_key", "a_rk_z_twin": "z_rk_z_fkref"])
    }

    @Test("An INCLUDE column must be in the covering index, and the widest cover is named")
    func includeColumns() {
        let indexes = [
            IndexRow(table: "ri_incl", name: "k_a_incl_c", keys: ["a"], includes: ["c"]),
            IndexRow(table: "ri_incl", name: "k_ab2", keys: ["a", "b"]),
            IndexRow(table: "ri_incl", name: "r_a_only", keys: ["a"])
        ]
        #expect(redundant(indexes) == ["r_a_only": "k_ab2"])

        let withCover = indexes + [IndexRow(table: "ri_incl", name: "k_abc_incl", keys: ["a", "b"], includes: ["c"])]
        #expect(redundant(withCover) == ["k_a_incl_c": "k_abc_incl", "k_ab2": "k_abc_incl", "r_a_only": "k_abc_incl"])
    }

    @Test("A GiST or GIN index is redundant only to an equal one, never to a longer one")
    func nonBTreeNeedsEqualKeys() {
        let found = redundant([
            IndexRow(table: "rx", name: "rx_room_during_excl", method: "gist", protected: true, keys: ["room", "during"]),
            IndexRow(table: "rx", name: "k_rx_room_gist", method: "gist", keys: ["room"]),
            IndexRow(name: "k_note_gin", method: "gin", keys: [Key("to_tsvector('simple'::regconfig, note)", opclass: "10073")]),
            IndexRow(name: "k_note_gin_2", method: "gin", keys: [Key("to_tsvector('english'::regconfig, note)", opclass: "10073")]),
            IndexRow(name: "r_note_gin_dup", method: "gin", keys: [Key("to_tsvector('simple'::regconfig, note)", opclass: "10073")])
        ])
        #expect(found == ["r_note_gin_dup": "k_note_gin"])
    }

    @Test("A redundant index previews a concurrent drop and carries its size and both definitions")
    func redundantFinding() throws {
        let finding = try #require(findings([
            IndexRow(schema: "sales", table: "orders", name: "orders_a_idx", bytes: "16384", keys: ["a"]),
            IndexRow(schema: "sales", table: "orders", name: "orders_ab_idx", keys: ["a", "b"])
        ]).first)
        #expect(finding.schema == "sales")
        #expect(finding.table == "orders")
        #expect(finding.objectName == "orders_a_idx")
        #expect(finding.sizeBytes == 16_384)
        #expect(finding.fixSQL == #"DROP INDEX CONCURRENTLY "sales"."orders_a_idx";"#)
        #expect(finding.metric("covering_index")?.value == .text("orders_ab_idx"))
        #expect(finding.metric("index_definition")?.value == .text("CREATE INDEX orders_a_idx ON sales.orders"))
        #expect(finding.metric("covering_definition")?.value == .text("CREATE INDEX orders_ab_idx ON sales.orders"))
        #expect(finding.metric("index_bytes") == nil)
        #expect(finding.detail == String(format: String(localized: "%1$@ is covered by %2$@."), "orders_a_idx", "orders_ab_idx"))
    }

    @Test("On a partitioned table the drop is not concurrent, which PostgreSQL refuses there")
    func partitionedDropIsPlain() throws {
        let finding = try #require(findings([
            IndexRow(table: "rp", tableKind: "p", name: "r_rp_k", bytes: "0", keys: ["k"]),
            IndexRow(table: "rp", tableKind: "p", name: "k_rp_k_at", bytes: "0", keys: ["k", "at"])
        ]).first)
        #expect(finding.objectName == "r_rp_k")
        #expect(finding.fixSQL == #"DROP INDEX "public"."r_rp_k";"#)
        #expect(finding.detail.contains("every partition"))
    }

    @Test("Indexes group by schema and table and order by position, whatever order the rows arrive in")
    func rowsGroupByExactNames() {
        let rows = Self.rows([
            IndexRow(schema: "a", table: "t", name: "t_x", keys: ["x"]),
            IndexRow(schema: "b", table: "t", name: "t_xy", keys: ["x", "y"]),
            IndexRow(schema: "a", table: "t", name: "t_yx", keys: ["y", "x"])
        ])
        let found = findings(rows: rows.reversed())
        #expect(found.isEmpty)

        let sameTable = Self.rows([
            IndexRow(name: "r_a", keys: ["a"]),
            IndexRow(name: "k_ab", keys: ["a", "b"])
        ])
        let shuffled = [sameTable[2], sameTable[0], sameTable[1]]
        #expect(findings(rows: shuffled).map { $0.objectName } == ["r_a"])
    }
}
