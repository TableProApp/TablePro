import Foundation
@testable import TableProPluginKit
import Testing

// SQLite lexes by scalar: a quote or a line feed followed by a combining mark is one Character, never one token.
struct SQLiteSQLScannerScalarTests {
    private static func rebuildContext(dependents: [String]) async throws -> SQLiteTableRebuildPlanner.Context? {
        try await SQLiteTableRebuildPlanner.context(tableName: "t") { query in
            let rows: [[PluginCellValue]]
            if query.contains("type = 'table'") {
                rows = [[.text("CREATE TABLE t (a INT, b TEXT)")]]
            } else if query.contains("type IN ('index', 'trigger')") {
                rows = dependents.map { [.text($0)] }
            } else if query.hasPrefix("PRAGMA table_xinfo") {
                rows = [
                    [.text("0"), .text("a"), .text("INT"), .text("0"), .null, .text("0"), .text("0")],
                    [.text("1"), .text("b"), .text("TEXT"), .text("0"), .null, .text("0"), .text("0")],
                ]
            } else if query.hasPrefix("PRAGMA") {
                rows = [[.text("0")]]
            } else {
                rows = []
            }
            return PluginQueryResult(columns: [], columnTypeNames: [], rows: rows, rowsAffected: 0, executionTime: 0)
        }
    }

    // Run as a script, `/* open;` swallows the next index up to the `*/` its predicate holds, and the DROP runs.
    @Test("An index stored with an open comment refuses the rebuild")
    func dependentEndingOpenRefuses() async throws {
        let context = try await Self.rebuildContext(dependents: [
            "CREATE INDEX i1 ON t(a) /* open",
            "CREATE INDEX i2 ON t(a) WHERE b <> '*/; DROP TABLE invoices; --'",
        ])
        #expect(context == nil)
    }

    @Test("An index stored with a trailing line comment ends on its own line")
    func dependentEndingInLineCommentKeepsItsLineEnd() async throws {
        let context = try #require(try await Self.rebuildContext(dependents: ["CREATE INDEX i1 ON t(a) -- note"]))
        #expect(context.dependentObjectSQL == ["CREATE INDEX i1 ON t(a) -- note\n"])
    }

    @Test("A doubled quote followed by a combining mark stays inside the literal, so its commas split nothing")
    func doubledQuoteWithCombiningMark() throws {
        let parsed = try #require(
            SQLiteTableDDL.parse(createTableSQL: "CREATE TABLE t (a TEXT DEFAULT 'p''\u{301}, b INT', c INT)")
        )
        #expect(parsed.columnNames == ["a", "c"])
        #expect(parsed.entries.first?.text == "a TEXT DEFAULT 'p''\u{301}, b INT'")
    }

    @Test("A line comment ends at the line feed of a CRLF")
    func lineCommentEndsAtCRLF() throws {
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: "CREATE TABLE t (a INT -- note\r\n, b INT)"))
        #expect(parsed.columnNames == ["a", "b"])
    }

    @Test("A literal's quote followed by a combining mark is one token, with its range over the source")
    func tokenizerKeepsTheLiteralWhole() {
        let sql = "a TEXT DEFAULT 'p''\u{301}, b' -- x\r\nNOT NULL"
        let tokens = SQLiteTokenizer.tokenize(sql)
        #expect(tokens.map(\.text) == ["a", "TEXT", "DEFAULT", "p'\u{301}, b", "NOT", "NULL"])
        #expect(tokens.dropFirst(3).first.map { String(sql[$0.range]) } == "'p''\u{301}, b'")
    }

    @Test("A parenthesis followed by a combining mark still opens the column list")
    func parenthesisWithCombiningMark() throws {
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: "CREATE TABLE t (\u{301}a INT, b INT)"))
        #expect(parsed.columnNames == ["\u{301}a", "b"])
        #expect(parsed.prefix.unicodeScalars.last == "(")
    }

    @Test("A trailing no-break space is part of the name, as SQLite reads it")
    func trailingNoBreakSpaceStaysInTheName() throws {
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: "CREATE TABLE t (a INT, x\u{A0})"))
        #expect(parsed.columnNames == ["a", "x\u{A0}"])
    }

    // MARK: - Comments

    @Test("Every scalar of `/*/ x */` reads as comment")
    func slashStarSlashOpensABlockComment() {
        var scanner = SQLiteSQLScanner("/*/ x */")
        var flags: [Bool] = []
        while scanner.next() != nil { flags.append(scanner.isInsideLiteral) }
        #expect(flags == [true, true, true, true, true, true])
    }

    @Test("`/*/` keeps the comment open, so dropping the key rebuilds without a second statement")
    func slashStarSlashHidesNoStatement() throws {
        let parsed = try #require(
            SQLiteTableDDL.parse(
                createTableSQL: "CREATE TABLE t (a INT, CONSTRAINT fk FOREIGN KEY (a) REFERENCES p(id) /*/) ; DROP TABLE invoices; --*/)"
            )
        )
        #expect(parsed.entries.map { $0.text } == ["a INT", "CONSTRAINT fk FOREIGN KEY (a) REFERENCES p(id) /*/) ; DROP TABLE invoices; --*/"])
        #expect(parsed.suffix == ")")

        let rebuilt = try #require(
            SQLiteTableDDL.respecified(
                parsed,
                tableName: "t",
                respecification: PluginTableRespecification(
                    droppedForeignKeys: [PluginForeignKeyDefinition(name: "fk", columns: ["a"], referencedTable: "p", referencedColumns: ["id"])]
                ),
                renderColumn: { _ in "" }
            )
        )
        #expect(rebuilt.createTableSQL == "CREATE TABLE \"t\" (\n  a INT\n)")
    }

    @Test("A line comment right after a word is still a comment")
    func lineCommentGluedToAWord() {
        #expect(SQLiteTokenizer.tokenize("b INT--x DEFAULT (1)\nNOT NULL").map { $0.text } == ["b", "INT", "NOT", "NULL"])
    }

    @Test("Retyping a column keeps a comment glued to its type a comment")
    func retypeKeepsAGluedComment() throws {
        let parsed = try #require(
            SQLiteTableDDL.parse(createTableSQL: "CREATE TABLE t (a INT, b INT--x CHECK (a; DROP TABLE invoices; SELECT 1)\n)")
        )
        let rebuilt = try #require(
            SQLiteTableDDL.respecified(
                parsed,
                tableName: "t",
                respecification: PluginTableRespecification(alteredColumns: [PluginColumnAlteration(column: "b", type: "TEXT")]),
                renderColumn: { _ in "" }
            )
        )
        #expect(rebuilt.createTableSQL == "CREATE TABLE \"t\" (\n  a INT,\n  b TEXT--x CHECK (a; DROP TABLE invoices; SELECT 1)\n\n)")
    }

    @Test("An entry ending in a line comment keeps its line feed, so the rebuilt comma stays code")
    func lineCommentEntryKeepsItsLineFeed() throws {
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: "CREATE TABLE t (a INT, b INT -- note\n)"))
        #expect(parsed.entries.map { $0.text } == ["a INT", "b INT -- note\n"])

        let rebuilt = try #require(
            SQLiteTableDDL.respecified(
                parsed,
                tableName: "t",
                respecification: PluginTableRespecification(
                    addedColumns: [PluginColumnDefinition(name: "c", dataType: "TEXT", isNullable: true)],
                    alteredColumns: [PluginColumnAlteration(column: "a", type: "TEXT")]
                ),
                renderColumn: { "\"\($0.name)\" \($0.dataType)" }
            )
        )
        #expect(rebuilt.createTableSQL == "CREATE TABLE \"t\" (\n  a TEXT,\n  b INT -- note\n,\n  \"c\" TEXT\n)")
        #expect(rebuilt.carriedColumns.map { $0.name } == ["a", "b"])
    }

    @Test("Reordering a column that ends in a line comment keeps the next column out of the comment")
    func reorderKeepsTheLineCommentEnd() throws {
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: "CREATE TABLE t (a INT, b INT -- note\n)"))
        #expect(SQLiteTableDDL.reordered(parsed, to: ["b", "a"], tableName: "t") == "CREATE TABLE \"t\" (\n  b INT -- note\n,\n  a INT\n)")
    }

    @Test("Cutting a key that follows a line comment keeps the comment's line feed")
    func cutAfterALineComment() throws {
        let parsed = try #require(
            SQLiteTableDDL.parse(createTableSQL: "CREATE TABLE t (a INT, b INT -- note\n REFERENCES p(id) NOT NULL)")
        )
        let rebuilt = try #require(
            SQLiteTableDDL.respecified(
                parsed,
                tableName: "t",
                respecification: PluginTableRespecification(
                    droppedForeignKeys: [PluginForeignKeyDefinition(name: "", columns: ["b"], referencedTable: "p", referencedColumns: ["id"])]
                ),
                renderColumn: { _ in "" }
            )
        )
        #expect(rebuilt.createTableSQL == "CREATE TABLE \"t\" (\n  a INT,\n  b INT -- note\nNOT NULL\n)")
    }

    @Test("An entry that starts with a comment is still a column", arguments: [
        "CREATE TABLE t (id INT, -- key\n name TEXT)",
        "CREATE TABLE t (id INT, /* key */ name TEXT)"
    ])
    func leadingCommentEntryIsAColumn(sql: String) throws {
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: sql))
        #expect(parsed.columnNames == ["id", "name"])
    }

    @Test("WITHOUT ROWID inside a comment between the table options is not the option")
    func commentedWithoutRowidIsNotTheOption() throws {
        let commented = try #require(
            SQLiteTableDDL.parse(createTableSQL: "CREATE TABLE t (a INT PRIMARY KEY) /* WITHOUT ROWID */ STRICT")
        )
        let declared = try #require(
            SQLiteTableDDL.parse(createTableSQL: "CREATE TABLE t (a INT PRIMARY KEY) STRICT, WITHOUT ROWID")
        )
        #expect(SQLiteTableDDL.isRowidTable(commented))
        #expect(!SQLiteTableDDL.isRowidTable(declared))
    }

    @Test("The table options are written from tokens, so a comment after them stays out of the script")
    func tableOptionsAreWrittenFromTokens() throws {
        let rebuilt = try retype(
            "a",
            to: "TEXT",
            in: "CREATE TABLE t (a INT PRIMARY KEY, \"x*/; DROP TABLE invoices; --\" TEXT) WITHOUT ROWID /* note */",
            table: "t"
        )
        #expect(rebuilt.hasSuffix("\n) WITHOUT ROWID"))
        #expect(rebuilt == "CREATE TABLE \"t\" (\n  a TEXT PRIMARY KEY,\n  \"x*/; DROP TABLE invoices; --\" TEXT\n) WITHOUT ROWID")
    }

    @Test("Anything after the column list but WITHOUT ROWID and STRICT refuses the rebuild", arguments: [
        "CREATE TABLE t (a INT PRIMARY KEY, \"x*/; DROP TABLE invoices; --\" TEXT) WITHOUT ROWID /* open",
        "CREATE TABLE t (a INT) /* open",
        "CREATE TABLE t (a INT) STRICT; DROP TABLE invoices",
        "CREATE TABLE t (a INT PRIMARY KEY) WITHOUT \"rowid\"",
        "CREATE TABLE t (a INT) STRICT,"
    ])
    func unknownTableOptionsRefuse(sql: String) {
        #expect(SQLiteTableDDL.parse(createTableSQL: sql) == nil)
    }

    @Test("STRICT and WITHOUT ROWID are both kept, in one order, without the comments between them", arguments: [
        "CREATE TABLE t (a INT PRIMARY KEY, b TEXT) STRICT, WITHOUT ROWID",
        "CREATE TABLE t (a INT PRIMARY KEY, b TEXT) strict /* c */ , /* d */ without rowid -- e"
    ])
    func bothTableOptionsAreKept(sql: String) throws {
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: sql))
        #expect(!SQLiteTableDDL.isRowidTable(parsed))
        #expect(
            SQLiteTableDDL.reordered(parsed, to: ["b", "a"], tableName: "t")
                == "CREATE TABLE \"t\" (\n  b TEXT,\n  a INT PRIMARY KEY\n) WITHOUT ROWID, STRICT"
        )
    }

    // MARK: - Whitespace

    @Test("A vertical tab is whitespace, so the NOT NULL after it survives a retype")
    func verticalTabIsWhitespace() throws {
        let rebuilt = try retype("b", to: "TEXT", in: "CREATE TABLE t5 (a INT, b INT -- c\n\u{0B}NOT NULL)", table: "t5")
        #expect(rebuilt == "CREATE TABLE \"t5\" (\n  a INT,\n  b TEXT -- c\n\u{0B}NOT NULL\n)")
    }

    @Test("A retype keeps a trailing no-break space in the referenced table's name")
    func retypeKeepsANoBreakSpaceInTheReference() throws {
        let rebuilt = try retype("b", to: "TEXT", in: "CREATE TABLE k (a INT, b INT REFERENCES p\u{A0})", table: "k")
        #expect(rebuilt == "CREATE TABLE \"k\" (\n  a INT,\n  b TEXT REFERENCES p\u{A0}\n)")
    }

    @Test("INTEGER followed by a no-break space is another type, so its key is not the rowid alias")
    func noBreakSpaceAfterIntegerIsNotTheAlias() throws {
        let sql = "CREATE TABLE r (id INTEGER\u{A0} PRIMARY KEY, v TEXT)"
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: sql))
        #expect(SQLiteTableDDL.rowidAliasColumn(parsed) == nil)
        let rebuilt = try retype("id", to: "TEXT", in: sql, table: "r")
        #expect(rebuilt == "CREATE TABLE \"r\" (\n  id TEXT PRIMARY KEY,\n  v TEXT\n)")
    }

    private func retype(_ column: String, to type: String, in sql: String, table: String) throws -> String {
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: sql))
        let rebuilt = try #require(
            SQLiteTableDDL.respecified(
                parsed,
                tableName: table,
                respecification: PluginTableRespecification(alteredColumns: [PluginColumnAlteration(column: column, type: type)]),
                renderColumn: { _ in "" }
            )
        )
        return rebuilt.createTableSQL
    }
}
