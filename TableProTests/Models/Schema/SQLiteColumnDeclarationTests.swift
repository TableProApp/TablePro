//
//  SQLiteColumnDeclarationTests.swift
//  TablePro
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

/// The column-definition grammar the rebuild rewrites through.
///
/// Every refusal and every boundary here was measured against SQLite 3.54, and several of them
/// refute what the published railroad diagrams say.
@Suite("SQLite Column Declaration")
struct SQLiteColumnDeclarationTests {
    private func parse(_ text: String) throws -> SQLiteColumnDeclaration {
        try #require(SQLiteColumnDeclaration.parse(text))
    }

    private func rewrite(
        _ text: String,
        type: String? = nil,
        isNullable: Bool? = nil,
        defaultValue: String? = nil
    ) -> String? {
        SQLiteColumnDeclaration.rewritten(
            text,
            applying: SQLiteColumnDeclaration.Edit(
                type: type, isNullable: isNullable, defaultValue: defaultValue
            )
        )
    }

    // MARK: - The type boundary

    /// A type name is one or more words, so the boundary is the first keyword that starts a
    /// constraint. Measured: `UNSIGNED BIG INT` and `VARYING CHARACTER(255)` are each one type.
    @Test(
        "The declared type is read whole",
        arguments: [
            ("a INTEGER", "INTEGER"),
            ("a UNSIGNED BIG INT", "UNSIGNED BIG INT"),
            ("a DOUBLE PRECISION", "DOUBLE PRECISION"),
            ("a VARYING CHARACTER(255)", "VARYING CHARACTER(255)"),
            ("a DECIMAL(10,2)", "DECIMAL(10,2)"),
            ("a TEXT NOT NULL", "TEXT"),
            ("a TEXT DEFAULT 'x'", "TEXT"),
            ("a INT REFERENCES p(id)", "INT")
        ]
    )
    func readsTheType(text: String, expected: String) throws {
        #expect(try parse(text).declaredType == expected)
    }

    /// `CREATE TABLE t(a)` is legal and declares no type at all.
    @Test("A column with no type has none, and a bare NULL is a constraint rather than one")
    func readsAnAbsentType() throws {
        #expect(try parse("a").declaredType == nil)
        #expect(try parse("a NULL").declaredType == nil)
        #expect(try parse("a NULL").first(.null) != nil)
    }

    /// Measured: `a BIG GENERATED` declares the type `BIG GENERATED`, and only the exact run
    /// `GENERATED ALWAYS AS` ends a type. A one-token lookahead gets this wrong.
    @Test("GENERATED ends the type only as the full three-word run")
    func readsGeneratedBoundary() throws {
        #expect(try parse("a BIG GENERATED ALWAYS AS (x)").declaredType == "BIG")
        #expect(try parse("a BIG GENERATED ALWAYS AS (x)").isGenerated)
        #expect(try parse("a TEXT AS (x)").declaredType == "TEXT")
        #expect(try parse("a TEXT AS (x)").isGenerated)
    }

    // MARK: - Which NULL is which

    /// The reason this is a grammar walk and not a keyword search. Measured on 3.54: the column is
    /// nullable, but a search for `NOT NULL` matches inside the check, so "make it NOT NULL" would
    /// read as already done and silently change nothing.
    @Test("NOT NULL inside a CHECK is not the column's nullability")
    func ignoresNotNullInsideACheck() throws {
        let declaration = try parse("b TEXT CHECK (b IS NOT NULL)")
        #expect(declaration.first(.notNull) == nil)
        #expect(declaration.first(.check) != nil)

        #expect(
            rewrite("b TEXT CHECK (b IS NOT NULL)", isNullable: false)
                == "b TEXT NOT NULL CHECK (b IS NOT NULL)"
        )
    }

    /// The other direction, and the one that produced a syntax error rather than a silent no-op:
    /// a search for `NULL` matches the foreign key's action and rewrites it into nonsense.
    @Test("NULL inside a referential action is not the column's nullability")
    func ignoresNullInsideAReferentialAction() throws {
        let text = "a INTEGER REFERENCES p(id) ON DELETE SET NULL"
        let declaration = try parse(text)
        #expect(declaration.first(.null) == nil)
        #expect(declaration.first(.notNull) == nil)
        #expect(declaration.first(.foreignKey) != nil)

        #expect(rewrite(text, isNullable: false) == "a INTEGER NOT NULL REFERENCES p(id) ON DELETE SET NULL")
    }

    // MARK: - Rewriting

    @Test("Changing the type leaves every other constraint byte for byte")
    func changesTheType() throws {
        let text = "b TEXT NOT NULL DEFAULT 'hi, there' COLLATE NOCASE CHECK (length(b) > 0)"
        let rewritten = try #require(rewrite(text, type: "VARCHAR(64)"))
        #expect(rewritten == "b VARCHAR(64) NOT NULL DEFAULT 'hi, there' COLLATE NOCASE CHECK (length(b) > 0)")
    }

    @Test("A column with no type gains one after its name")
    func addsATypeToAnUntypedColumn() throws {
        #expect(rewrite("a NOT NULL", type: "TEXT") == "a TEXT NOT NULL")
    }

    /// Dropping the constraint takes its `ON CONFLICT` tail with it: measured, an orphaned
    /// `ON CONFLICT ROLLBACK` is a parse error.
    @Test("Dropping NOT NULL takes its whole clause")
    func dropsNotNull() throws {
        #expect(rewrite("a TEXT NOT NULL", isNullable: true) == "a TEXT")
        #expect(rewrite("a TEXT NOT NULL ON CONFLICT ROLLBACK", isNullable: true) == "a TEXT")
        #expect(rewrite("a TEXT CONSTRAINT nn NOT NULL", isNullable: true) == "a TEXT")
    }

    @Test("A bare NULL becomes NOT NULL rather than gaining a second clause")
    func replacesABareNull() throws {
        #expect(rewrite("a TEXT NULL", isNullable: false) == "a TEXT NOT NULL")
    }

    @Test("Changing the default replaces only its clause")
    func changesTheDefault() throws {
        #expect(rewrite("a TEXT DEFAULT 'old' NOT NULL", defaultValue: "'new'") == "a TEXT DEFAULT 'new' NOT NULL")
        #expect(rewrite("a TEXT NOT NULL", defaultValue: "'new'") == "a TEXT DEFAULT 'new' NOT NULL")
        #expect(rewrite("a TEXT", defaultValue: "'new'") == "a TEXT DEFAULT 'new'")
        #expect(rewrite("a TEXT DEFAULT 'old'", defaultValue: "") == "a TEXT")
    }

    /// Measured: `PRAGMA table_info` reports this default as `datetime('now')`, and re-emitting the
    /// stripped form is a syntax error. It survives only because an untouched clause is never
    /// re-rendered.
    @Test("An expression default is left exactly as written when something else changes")
    func preservesAnExpressionDefault() throws {
        let text = "a TEXT DEFAULT (datetime('now'))"
        #expect(rewrite(text, type: "DATETIME") == "a DATETIME DEFAULT (datetime('now'))")
        #expect(rewrite(text, isNullable: false) == "a TEXT NOT NULL DEFAULT (datetime('now'))")
    }

    @Test("A signed-number default is one clause")
    func readsASignedNumberDefault() throws {
        #expect(try parse("a INT DEFAULT -1 NOT NULL").first(.defaultValue) != nil)
        #expect(rewrite("a INT DEFAULT -1 NOT NULL", type: "BIGINT") == "a BIGINT DEFAULT -1 NOT NULL")
    }

    @Test("Several edits to one column all land")
    func appliesSeveralEditsAtOnce() throws {
        let rewritten = try #require(
            rewrite("a TEXT DEFAULT 'old'", type: "INTEGER", isNullable: false, defaultValue: "0")
        )
        #expect(rewritten == "a INTEGER NOT NULL DEFAULT 0")
    }

    // MARK: - Refusals

    /// Measured: retyping an `INTEGER PRIMARY KEY` to `TEXT PRIMARY KEY` destroys the rowid alias.
    /// The key stops generating values and then stores NULL on every insert that omits it, twice
    /// over, with no error. Refusing is the only safe answer.
    @Test("Retyping an INTEGER PRIMARY KEY away from INTEGER is refused")
    func refusesToDestroyTheRowidAlias() {
        #expect(rewrite("id INTEGER PRIMARY KEY", type: "TEXT") == nil)
        #expect(rewrite("id INTEGER PRIMARY KEY AUTOINCREMENT", type: "TEXT") == nil)
        /// Still the alias, so still allowed.
        #expect(rewrite("id INTEGER PRIMARY KEY", type: "integer") != nil)
        /// Not the alias to begin with.
        #expect(rewrite("id TEXT PRIMARY KEY", type: "INTEGER") != nil)
    }

    /// Measured: `a INT NOT NULL NOT NULL` and `a INT DEFAULT 1 DEFAULT 2` are both legal.
    /// Rewriting one of a pair leaves the other in force, so the edit would report success and
    /// change nothing.
    @Test("A column carrying the same constraint twice is refused")
    func refusesDuplicateConstraints() {
        #expect(rewrite("a INT NOT NULL NOT NULL", isNullable: true) == nil)
        #expect(rewrite("a INT DEFAULT 1 DEFAULT 2", defaultValue: "3") == nil)
        /// The other edits are still fine on the same column.
        #expect(rewrite("a INT NOT NULL NOT NULL", type: "BIGINT") != nil)
    }

    /// A generated column's nullability and default belong to its expression, and SQLite rejects a
    /// `DEFAULT` on one outright.
    @Test("Nullability and default edits are refused on a generated column")
    func refusesEditsToAGeneratedColumn() {
        #expect(rewrite("a TEXT GENERATED ALWAYS AS (b) VIRTUAL", isNullable: false) == nil)
        #expect(rewrite("a TEXT GENERATED ALWAYS AS (b) VIRTUAL", defaultValue: "'x'") == nil)
        #expect(rewrite("a TEXT GENERATED ALWAYS AS (b) VIRTUAL", type: "INT") != nil)
    }

    @Test("A table constraint entry is not a column")
    func refusesATableConstraint() {
        #expect(SQLiteColumnDeclaration.parse("PRIMARY KEY (a, b)") == nil)
        #expect(SQLiteColumnDeclaration.parse("CONSTRAINT fk FOREIGN KEY (a) REFERENCES p (id)") == nil)
        #expect(SQLiteColumnDeclaration.parse("CHECK (a > 0)") == nil)
        #expect(SQLiteColumnDeclaration.parse("UNIQUE (a)") == nil)
    }

    /// A declaration this grammar cannot read whole is never rewritten from a partial
    /// understanding: the rebuild refuses instead and the user writes the SQL themselves.
    @Test("An unreadable declaration is refused rather than guessed at")
    func refusesWhatItCannotRead() {
        #expect(SQLiteColumnDeclaration.parse("a TEXT CHECK (") == nil)
        #expect(SQLiteColumnDeclaration.parse("a TEXT COLLATE") == nil)
        #expect(SQLiteColumnDeclaration.parse("a TEXT NOT") == nil)
    }

    // MARK: - Quoting

    @Test("A quoted type name is a type, not a keyword")
    func readsAQuotedType() throws {
        #expect(try parse("a \"DEFAULT\" NOT NULL").declaredType == "\"DEFAULT\"")
        #expect(try parse("a \"DEFAULT\" NOT NULL").first(.notNull) != nil)
        #expect(try parse("a \"DEFAULT\" NOT NULL").first(.defaultValue) == nil)
    }

    @Test("A quoted column name keeps its spelling")
    func readsAQuotedName() throws {
        #expect(try parse("\"my col\" TEXT").name == "my col")
        #expect(rewrite("\"my col\" TEXT", type: "INT") == "\"my col\" INT")
    }
}
