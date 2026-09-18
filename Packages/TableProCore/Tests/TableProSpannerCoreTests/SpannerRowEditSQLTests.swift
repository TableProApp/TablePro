import Foundation
import TableProSpannerCore
import Testing

@Suite("SpannerRowEditSQL")
struct SpannerRowEditSQLTests {
    private typealias Cell = SpannerRowChange.CellChange

    private func generate(
        schema: String = "",
        table: String = "Singers",
        columns: [String] = ["Id", "Name", "Photo"],
        primaryKey: [String] = ["Id"],
        changes: [SpannerRowChange],
        insertedRows: [Int: [SpannerCell]] = [:],
        deletedRows: Set<Int> = [],
        insertedRowIndices: Set<Int> = [],
        dialect: SpannerDialect = .googleSQL
    ) -> [SpannerRenderedStatement]? {
        SpannerRowEditSQL.statements(
            schema: schema, table: table, columns: columns, primaryKey: primaryKey, changes: changes,
            insertedRows: insertedRows, deletedRows: deletedRows, insertedRowIndices: insertedRowIndices, dialect: dialect
        )
    }

    @Test("The sentinel is __DEFAULT__")
    func sentinel() {
        #expect(SpannerRowEditSQL.defaultSentinel == "__DEFAULT__")
    }

    @Test("An insert skips sentinel cells and binds every other value, NULL included")
    func insertSkipsSentinel() throws {
        let statements = try #require(generate(
            table: "T2", columns: ["Id", "D", "G", "N"],
            changes: [SpannerRowChange(rowIndex: 0, kind: .insert)],
            insertedRows: [0: [.text("900"), .text("__DEFAULT__"), .text("__DEFAULT__"), .null]],
            insertedRowIndices: [0]
        ))
        #expect(statements == [SpannerRenderedStatement(
            sql: "INSERT INTO `T2` (`Id`, `N`) VALUES (?, ?)",
            parameters: [.text("900"), .null]
        )])
        #expect(statements.first?.parameterTypes == nil)
    }

    @Test("An insert whose every cell is the sentinel writes DEFAULT into the first column")
    func allSentinelInsert() throws {
        let statements = try #require(generate(
            table: "T3", columns: ["Id", "V"],
            changes: [SpannerRowChange(rowIndex: 4, kind: .insert)],
            insertedRows: [4: [.text("__DEFAULT__"), .text("__DEFAULT__")]],
            insertedRowIndices: [4]
        ))
        #expect(statements == [SpannerRenderedStatement(sql: "INSERT INTO `T3` (`Id`) VALUES (DEFAULT)")])
    }

    @Test("An insert without row data uses its cell changes")
    func insertFromCellChanges() throws {
        let statements = try #require(generate(
            changes: [SpannerRowChange(rowIndex: 0, kind: .insert, cellChanges: [
                Cell(column: "Id", value: .text("1")), Cell(column: "Name", value: .text("a")),
                Cell(column: "Name", value: .text("b")), Cell(column: "Photo", value: .text("__DEFAULT__"))
            ])],
            insertedRowIndices: [0]
        ))
        #expect(statements == [SpannerRenderedStatement(
            sql: "INSERT INTO `Singers` (`Id`, `Name`) VALUES (?, ?)",
            parameters: [.text("1"), .text("b")]
        )])
    }

    @Test("Inserts and deletes outside their index sets are ignored")
    func respectsIndexSets() throws {
        let statements = try #require(generate(
            changes: [
                SpannerRowChange(rowIndex: 0, kind: .insert, cellChanges: [Cell(column: "Id", value: .text("1"))]),
                SpannerRowChange(rowIndex: 1, kind: .delete, originalRow: [.text("2"), .null, .null])
            ]
        ))
        #expect(statements.isEmpty)
    }

    @Test("An update binds values, writes DEFAULT for the sentinel and keys on the original row")
    func update() throws {
        let statements = try #require(generate(
            changes: [SpannerRowChange(rowIndex: 3, kind: .update, cellChanges: [
                Cell(column: "Name", value: .text("x' OR TRUE --")),
                Cell(column: "Photo", value: .bytes(Data([0, 1, 2]))),
                Cell(column: "Name", value: .text("It's \\ new")),
                Cell(column: "Age", value: .text("__DEFAULT__")),
                Cell(column: "Active", value: .null)
            ], originalRow: [.text("7"), .text("old"), .null])]
        ))
        #expect(statements == [SpannerRenderedStatement(
            sql: "UPDATE `Singers` SET `Name` = ?, `Photo` = ?, `Age` = DEFAULT, `Active` = ? WHERE `Id` = ?",
            parameters: [.text("It's \\ new"), .bytes(Data([0, 1, 2])), .null, .text("7")]
        )])
    }

    @Test("A composite key with a bytes column binds every key part")
    func compositeKey() throws {
        let statements = try #require(generate(
            table: "Docs", columns: ["Tenant", "K", "V"], primaryKey: ["Tenant", "K"],
            changes: [SpannerRowChange(rowIndex: 0, kind: .update, cellChanges: [Cell(column: "V", value: .text("v2b"))],
                                       originalRow: [.text("t1"), .bytes(Data([0, 2])), .text("v2")])]
        ))
        #expect(statements == [SpannerRenderedStatement(
            sql: "UPDATE `Docs` SET `V` = ? WHERE `Tenant` = ? AND `K` = ?",
            parameters: [.text("v2b"), .text("t1"), .bytes(Data([0, 2]))]
        )])
    }

    @Test("A NULL key part matches with IS NULL")
    func nullKey() throws {
        let statements = try #require(generate(
            table: "NK", columns: ["K", "V"], primaryKey: ["K"],
            changes: [
                SpannerRowChange(rowIndex: 0, kind: .update, cellChanges: [Cell(column: "V", value: .text("changed"))],
                                 originalRow: [.null, .text("nullkey")]),
                SpannerRowChange(rowIndex: 1, kind: .delete, originalRow: [.null, .text("x")])
            ],
            deletedRows: [1]
        ))
        #expect(statements == [
            SpannerRenderedStatement(sql: "UPDATE `NK` SET `V` = ? WHERE `K` IS NULL", parameters: [.text("changed")]),
            SpannerRenderedStatement(sql: "DELETE FROM `NK` WHERE `K` IS NULL", parameters: [])
        ])
    }

    @Test("A delete keys on the original row")
    func delete() throws {
        let statements = try #require(generate(
            changes: [SpannerRowChange(rowIndex: 2, kind: .delete, originalRow: [.text("901"), .text("n"), .null])],
            deletedRows: [2]
        ))
        #expect(statements == [SpannerRenderedStatement(sql: "DELETE FROM `Singers` WHERE `Id` = ?", parameters: [.text("901")])])
    }

    struct UnkeyableCase: Sendable, CustomTestStringConvertible {
        let label: String
        let primaryKey: [String]
        let originalRow: [SpannerCell]?
        var testDescription: String { label }
    }

    @Test("An update or delete that cannot be keyed refuses the whole batch", arguments: [
        UnkeyableCase(label: "key column not in the result", primaryKey: ["Other"], originalRow: [.text("1"), .null, .null]),
        UnkeyableCase(label: "no original row", primaryKey: ["Id"], originalRow: nil),
        UnkeyableCase(label: "no primary key", primaryKey: [], originalRow: [.text("1"), .null, .null]),
        UnkeyableCase(label: "original row too short", primaryKey: ["Photo"], originalRow: [.text("1")])
    ])
    func unkeyable(_ testCase: UnkeyableCase) {
        let primaryKey = testCase.primaryKey
        let update = SpannerRowChange(rowIndex: 0, kind: .update, cellChanges: [Cell(column: "Name", value: .text("x"))],
                                      originalRow: testCase.originalRow)
        let delete = SpannerRowChange(rowIndex: 1, kind: .delete, originalRow: testCase.originalRow)
        let fine = SpannerRowChange(rowIndex: 2, kind: .insert, cellChanges: [Cell(column: "Id", value: .text("9"))])
        #expect(generate(primaryKey: primaryKey, changes: [fine, update], insertedRowIndices: [2]) == nil)
        #expect(generate(primaryKey: primaryKey, changes: [fine, delete], deletedRows: [1], insertedRowIndices: [2]) == nil)
    }

    @Test("The ownership probe gets an empty batch")
    func ownershipProbe() {
        let probe = SpannerRowChange(rowIndex: 0, kind: .update)
        #expect(generate(primaryKey: [], changes: [probe])?.isEmpty == true)
        #expect(generate(changes: [])?.isEmpty == true)
    }

    @Test("Statement order follows the change order")
    func order() throws {
        let statements = try #require(generate(
            changes: [
                SpannerRowChange(rowIndex: 5, kind: .delete, originalRow: [.text("5"), .null, .null]),
                SpannerRowChange(rowIndex: 6, kind: .insert, cellChanges: [Cell(column: "Id", value: .text("6"))]),
                SpannerRowChange(rowIndex: 1, kind: .update, cellChanges: [Cell(column: "Name", value: .text("n"))],
                                 originalRow: [.text("1"), .null, .null])
            ],
            deletedRows: [5],
            insertedRowIndices: [6]
        ))
        #expect(statements.map(\.sql) == [
            "DELETE FROM `Singers` WHERE `Id` = ?",
            "INSERT INTO `Singers` (`Id`) VALUES (?)",
            "UPDATE `Singers` SET `Name` = ? WHERE `Id` = ?"
        ])
    }

    @Test("PostgreSQL quoting and the unqualified public schema")
    func postgres() throws {
        let statements = try #require(generate(
            schema: "public", table: "t2", columns: ["id", "d"], primaryKey: ["id"],
            changes: [SpannerRowChange(rowIndex: 0, kind: .update, cellChanges: [Cell(column: "d", value: .text("__DEFAULT__"))],
                                       originalRow: [.text("900"), .text("x")])],
            dialect: .postgreSQL
        ))
        #expect(statements == [SpannerRenderedStatement(sql: "UPDATE \"t2\" SET \"d\" = DEFAULT WHERE \"id\" = ?", parameters: [.text("900")])])
        let named = try #require(generate(
            schema: "sales", table: "orders", columns: ["id"], primaryKey: ["id"],
            changes: [SpannerRowChange(rowIndex: 0, kind: .delete, originalRow: [.text("1")])],
            deletedRows: [0], dialect: .postgreSQL
        ))
        #expect(named.map(\.sql) == ["DELETE FROM \"sales\".\"orders\" WHERE \"id\" = ?"])
    }

    @Test("A named GoogleSQL schema qualifies the table and hostile names stay quoted")
    func namedSchemaAndHostileNames() throws {
        let statements = try #require(generate(
            schema: "sales", table: "Or`ders", columns: ["Id", "a`b"], primaryKey: ["Id"],
            changes: [SpannerRowChange(rowIndex: 0, kind: .update, cellChanges: [Cell(column: "a`b", value: .text("v"))],
                                       originalRow: [.text("1"), .null])]
        ))
        #expect(statements.map(\.sql) == [#"UPDATE `sales`.`Or\`ders` SET `a\`b` = ? WHERE `Id` = ?"#])
    }

    @Test("An identity-preserving insert writes every column, sentinel text and NULL included")
    func identityPreserving() {
        let statements = SpannerRowEditSQL.identityPreservingInserts(
            schema: "", table: "T3", columns: ["Id", "V"],
            rows: [[.text("777"), .text("restored")], [.text("778"), .null], []],
            dialect: .googleSQL
        )
        #expect(statements == [
            SpannerRenderedStatement(sql: "INSERT INTO `T3` (`Id`, `V`) VALUES (?, ?)", parameters: [.text("777"), .text("restored")]),
            SpannerRenderedStatement(sql: "INSERT INTO `T3` (`Id`, `V`) VALUES (?, ?)", parameters: [.text("778"), .null])
        ])
        let postgres = SpannerRowEditSQL.identityPreservingInserts(
            schema: "sales", table: "orders", columns: ["id"], rows: [[.bytes(Data([1]))]], dialect: .postgreSQL
        )
        #expect(postgres == [SpannerRenderedStatement(sql: "INSERT INTO \"sales\".\"orders\" (\"id\") VALUES (?)", parameters: [.bytes(Data([1]))])])
    }
}
