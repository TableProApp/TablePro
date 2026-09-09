//
//  SQLiteForeignKeyClauseTests.swift
//  TablePro
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("SQLite Foreign Key Clause")
struct SQLiteForeignKeyClauseTests {
    private func clauses(_ sql: String) throws -> [SQLiteForeignKeyClause] {
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: sql))
        return SQLiteTableDDL.foreignKeys(in: parsed)
    }

    @Test("A table-level key is read with its name, its columns and both actions")
    func readsTableLevelKey() throws {
        let found = try clauses("""
            CREATE TABLE orders(
              id INTEGER PRIMARY KEY,
              customer_id INTEGER,
              CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id)
                REFERENCES customers (id) ON DELETE CASCADE ON UPDATE SET NULL
            )
            """)
        #expect(found.count == 1)
        #expect(found[0].name == "fk_orders_customer")
        #expect(found[0].columns == ["customer_id"])
        #expect(found[0].referencedTable == "customers")
        #expect(found[0].referencedColumns == ["id"])
        #expect(found[0].onDelete == "CASCADE")
        #expect(found[0].onUpdate == "SET NULL")
    }

    @Test("A column-level REFERENCES is a foreign key on that column")
    func readsColumnLevelKey() throws {
        let found = try clauses("CREATE TABLE t(id INTEGER PRIMARY KEY, pid INTEGER REFERENCES parent(id))")
        #expect(found.count == 1)
        #expect(found[0].name == nil)
        #expect(found[0].columns == ["pid"])
        #expect(found[0].referencedTable == "parent")
        #expect(found[0].referencedColumns == ["id"])
    }

    /// SQLite reads `REFERENCES parent` with no column list as the parent's primary key. The DDL
    /// does not say which column that is, so the clause carries none and the pragma resolves it.
    @Test("A reference with no column list carries no referenced columns")
    func readsImplicitParentKey() throws {
        let found = try clauses("CREATE TABLE t(pid INTEGER REFERENCES parent)")
        #expect(found.count == 1)
        #expect(found[0].referencedTable == "parent")
        #expect(found[0].referencedColumns.isEmpty)
    }

    @Test("A composite key is one clause with every column pair, in order")
    func readsCompositeKey() throws {
        let found = try clauses("""
            CREATE TABLE t(a INT, b INT, FOREIGN KEY (a, b) REFERENCES p (x, y))
            """)
        #expect(found.count == 1)
        #expect(found[0].columns == ["a", "b"])
        #expect(found[0].referencedColumns == ["x", "y"])
    }

    /// The word appears inside a string literal and inside a `CHECK`. A scan that did not know
    /// where a literal ends would read either as a foreign key.
    @Test("REFERENCES inside a literal or a CHECK is not a foreign key")
    func ignoresReferencesInsideLiteralsAndChecks() throws {
        let found = try clauses("""
            CREATE TABLE t(
              note TEXT DEFAULT 'references parent(id)',
              n INT CHECK (n <> 0),
              "references" TEXT,
              CHECK (note <> 'REFERENCES x')
            )
            """)
        #expect(found.isEmpty)
    }

    @Test("Quoted identifiers keep their spelling")
    func readsQuotedIdentifiers() throws {
        let found = try clauses("""
            CREATE TABLE t("my col" INT, FOREIGN KEY ("my col") REFERENCES "other table" ("its id"))
            """)
        #expect(found.count == 1)
        #expect(found[0].columns == ["my col"])
        #expect(found[0].referencedTable == "other table")
        #expect(found[0].referencedColumns == ["its id"])
    }

    @Test("Every key is found when a table declares several, in declaration order")
    func readsSeveralKeys() throws {
        let found = try clauses("""
            CREATE TABLE t(
              a INT REFERENCES p1(id),
              b INT,
              CONSTRAINT second FOREIGN KEY (b) REFERENCES p2(id)
            )
            """)
        #expect(found.map(\.referencedTable) == ["p1", "p2"])
        #expect(found.map(\.name) == [nil, "second"])
    }

    // MARK: - Rendering

    @Test("A rendered clause quotes every identifier")
    func rendersQuoted() {
        let clause = SQLiteForeignKeyClause(
            name: "fk_x",
            columns: ["a", "b"],
            referencedTable: "other table",
            referencedColumns: ["x", "y"],
            onDelete: "CASCADE",
            onUpdate: nil
        )
        #expect(clause.rendered == """
            CONSTRAINT "fk_x" FOREIGN KEY ("a", "b") REFERENCES "other table" ("x", "y") ON DELETE CASCADE
            """)
    }

    /// A quote inside an identifier is doubled, which is how SQLite escapes one. Getting this wrong
    /// ends the identifier early and turns the rest of the clause into a syntax error.
    @Test("A quote inside an identifier is doubled")
    func rendersEscapedQuotes() {
        let clause = SQLiteForeignKeyClause(
            name: "fk\"odd", columns: ["a"], referencedTable: "p", referencedColumns: ["id"]
        )
        #expect(clause.rendered.hasPrefix("CONSTRAINT \"fk\"\"odd\" FOREIGN KEY (\"a\")"))
    }

    /// `NO ACTION` is what SQLite does with no clause at all, so it is written as no clause. A
    /// rebuild that spelled it out would put words in the statement the user never wrote.
    @Test("NO ACTION renders as no clause at all")
    func omitsNoAction() throws {
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: "CREATE TABLE t(a INT)"))
        let respecified = try #require(
            SQLiteTableDDL.respecified(
                parsed,
                tableName: "t_new",
                respecification: PluginTableRespecification(
                    addedForeignKeys: [
                        PluginForeignKeyDefinition(
                            name: "fk", columns: ["a"], referencedTable: "p",
                            referencedColumns: ["id"], onDelete: "NO ACTION", onUpdate: "NO ACTION"
                        )
                    ]
                ),
                renderColumn: { _ in "" }
            )
        )
        #expect(!respecified.createTableSQL.contains("NO ACTION"))
        #expect(respecified.createTableSQL.contains("FOREIGN KEY (\"a\") REFERENCES \"p\" (\"id\")"))
    }

    @Test("A rendered clause round-trips through the parser")
    func renderedClauseParsesBack() throws {
        let clause = SQLiteForeignKeyClause(
            name: "fk_x",
            columns: ["a"],
            referencedTable: "p",
            referencedColumns: ["id"],
            onDelete: "SET NULL",
            onUpdate: "CASCADE"
        )
        let found = try clauses("CREATE TABLE t(a INT, \(clause.rendered))")
        #expect(found.count == 1)
        #expect(found[0] == clause)
    }

    // MARK: - Identity

    /// The name is optional in the DDL and absent from the pragma, and the actions are what an edit
    /// changes, so neither can decide which key the user asked to drop.
    @Test("Two clauses match on the relationship, not the name or the actions")
    func matchesOnRelationship() {
        let one = SQLiteForeignKeyClause(
            name: "a", columns: ["PID"], referencedTable: "Parent",
            referencedColumns: ["ID"], onDelete: "CASCADE", onUpdate: nil
        )
        let two = SQLiteForeignKeyClause(
            name: nil, columns: ["pid"], referencedTable: "parent",
            referencedColumns: ["id"], onDelete: nil, onUpdate: "CASCADE"
        )
        #expect(one.referencesSameRelationship(as: two))

        let other = SQLiteForeignKeyClause(
            name: "a", columns: ["pid"], referencedTable: "elsewhere", referencedColumns: ["id"]
        )
        #expect(!one.referencesSameRelationship(as: other))
    }
}
