//
//  TableEditStatementParserTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProSQLGrammar
import Testing

struct TableEditStatementParserTests {
    private static func parse(_ sql: String, _ type: DatabaseType) throws -> TableEditStatement {
        let dialect = try #require(TableEditDialect.of(type))
        return TableEditStatementParser.parse(sql, dialect: dialect, grammar: type.lexicalGrammar)
    }

    private static func bare(_ text: String) -> SQLNamePart {
        SQLNamePart(text: text, isQuoted: false)
    }

    private static func quoted(_ text: String) -> SQLNamePart {
        SQLNamePart(text: text, isQuoted: true)
    }

    private static func name(_ parts: SQLNamePart...) -> SQLObjectName {
        SQLObjectName(parts: parts)
    }

    // MARK: - Drop

    @Test("A drop reads every name in its list, as written, with IF EXISTS and CASCADE around it")
    func dropListWithOptions() throws {
        #expect(
            try Self.parse("DROP TABLE IF EXISTS People, public.\"Orders\" CASCADE", .postgresql)
                == .drop([Self.name(Self.bare("People")), Self.name(Self.bare("public"), Self.quoted("Orders"))], kind: .table)
        )
    }

    @Test("MySQL backticks and a database qualifier are read as parts")
    func mySQLBackticks() throws {
        #expect(
            try Self.parse("DROP TABLE `shop`.`order items`", .mysql)
                == .drop([Self.name(Self.quoted("shop"), Self.quoted("order items"))], kind: .table)
        )
    }

    @Test("SQL Server brackets are read as quoted parts")
    func sqlServerBrackets() throws {
        #expect(
            try Self.parse("DROP TABLE [sales].[dbo].[Order Items]", .mssql)
                == .drop([Self.name(Self.quoted("sales"), Self.quoted("dbo"), Self.quoted("Order Items"))], kind: .table)
        )
    }

    @Test("Views, materialized views and foreign tables are drops of their own kind")
    func dropKinds() throws {
        #expect(try Self.parse("DROP VIEW v", .postgresql) == .drop([Self.name(Self.bare("v"))], kind: .view))
        #expect(
            try Self.parse("DROP MATERIALIZED VIEW IF EXISTS m", .postgresql)
                == .drop([Self.name(Self.bare("m"))], kind: .materializedView)
        )
        #expect(
            try Self.parse("DROP FOREIGN TABLE f", .postgresql) == .drop([Self.name(Self.bare("f"))], kind: .foreignTable)
        )
    }

    @Test("Oracle's CASCADE CONSTRAINTS PURGE and ClickHouse's ON CLUSTER and SYNC are accepted")
    func engineSpecificTails() throws {
        #expect(
            try Self.parse("DROP TABLE hr.emp CASCADE CONSTRAINTS PURGE", .oracle)
                == .drop([Self.name(Self.bare("hr"), Self.bare("emp"))], kind: .table)
        )
        #expect(
            try Self.parse("DROP TABLE IF EXISTS logs.events ON CLUSTER main SYNC", .clickhouse)
                == .drop([Self.name(Self.bare("logs"), Self.bare("events"))], kind: .table)
        )
    }

    @Test("A temporary drop, an index drop and a drop followed by more text are not read")
    func dropsThatAreNotRead() throws {
        #expect(try Self.parse("DROP TEMPORARY TABLE IF EXISTS t", .mysql) == .other)
        #expect(try Self.parse("DROP INDEX idx", .postgresql) == .other)
        #expect(try Self.parse("DROP TABLE dbo.t\nSELECT 1", .mssql) == .other)
        #expect(try Self.parse("DROP MATERIALIZED VIEW mv PRESERVE TABLE", .oracle) == .other)
        #expect(try Self.parse("DROP TABLE archive..t", .mssql) == .other)
        #expect(Self.placesNothing("DROP TABLE @t", .mssql))
    }

    private static func placesNothing(_ sql: String, _ type: DatabaseType) -> Bool {
        guard let dialect = TableEditDialect.of(type),
              case .drop(let names, _) = TableEditStatementParser.parse(sql, dialect: dialect, grammar: type.lexicalGrammar)
        else { return true }
        return names.allSatisfy { dialect.resolve($0, in: TableNameContext(database: "db", schema: "dbo")) == nil }
    }

    @Test("A drop inside a MySQL executable comment is not read, since an older server skips it and succeeds")
    func versionGatedDropIsNotRead() throws {
        #expect(try Self.parse("/*!99999 DROP TABLE people */", .mysql) == .other)
        #expect(try Self.parse("DROP TABLE /*!32312 IF EXISTS*/ people", .mysql) == .other)
        #expect(try Self.parse("/*M!100100 DROP TABLE people */", .mariadb) == .other)
        #expect(
            try Self.parse("/*!40101 CREATE TEMPORARY TABLE people (id int) */", .mysql)
                == .createsTemporaryTable(Self.name(Self.bare("people")))
        )
    }

    @Test("A comment before the statement and a trailing semicolon change nothing")
    func commentsAndTerminator() throws {
        #expect(
            try Self.parse("-- tidy up\n/* old */ DROP TABLE t;", .postgresql) == .drop([Self.name(Self.bare("t"))], kind: .table)
        )
    }

    // MARK: - Rename

    @Test("ALTER TABLE ... RENAME TO reads the old and the new name")
    func alterRenameTo() throws {
        #expect(
            try Self.parse("ALTER TABLE s.people RENAME TO persons", .postgresql)
                == .rename([SQLRenamePair(from: Self.name(Self.bare("s"), Self.bare("people")), to: Self.name(Self.bare("persons")))], kind: .table)
        )
        #expect(
            try Self.parse("ALTER VIEW v RENAME TO w", .postgresql)
                == .rename([SQLRenamePair(from: Self.name(Self.bare("v")), to: Self.name(Self.bare("w")))], kind: .view)
        )
    }

    /// PostgreSQL answers a conditional rename of a missing table with a notice and no error, so
    /// reading it as a rename would move stale settings over the target's own.
    @Test("A conditional rename is not read, because it succeeds having renamed nothing")
    func conditionalRenameIsNotRead() throws {
        #expect(try Self.parse("ALTER TABLE IF EXISTS missing RENAME TO live", .postgresql) == .other)
    }

    @Test("SQL Server's sp_rename reads its object name as a multipart name and its new name as written")
    func sqlServerStoredProcedureRename() throws {
        let expected = TableEditStatement.rename(
            [SQLRenamePair(from: Self.name(Self.bare("dbo"), Self.bare("people")), to: Self.name(Self.quoted("persons")))],
            kind: .table
        )
        #expect(try Self.parse("EXEC sp_rename 'dbo.people', 'persons'", .mssql) == expected)
        #expect(try Self.parse("EXECUTE sys.sp_rename N'dbo.people', N'persons', 'OBJECT'", .mssql) == expected)
        #expect(
            try Self.parse("EXEC sp_rename N'[dbo].[Order Items]', N'Order''s', N'OBJECT'", .mssql)
                == .rename(
                    [SQLRenamePair(
                        from: Self.name(Self.quoted("dbo"), Self.quoted("Order Items")), to: Self.name(Self.quoted("Order's"))
                    )],
                    kind: .table
                )
        )
    }

    @Test("sp_rename of a column, an index, or with named arguments is not read")
    func otherStoredProcedureRenames() throws {
        #expect(try Self.parse("EXEC sp_rename 'dbo.people.name', 'full_name', 'COLUMN'", .mssql) == .other)
        #expect(try Self.parse("EXEC sp_rename N'dbo.people.ix_name', N'ix_full', N'INDEX'", .mssql) == .other)
        #expect(try Self.parse("EXEC sp_rename @objname = N'dbo.people', @newname = N'persons'", .mssql) == .other)
        #expect(try Self.parse("EXEC sp_helptext 'dbo.people'", .mssql) == .runsUnseenCode)
    }

    @Test("MySQL renames with AS or with no keyword at all")
    func mySQLRenameForms() throws {
        let expected = TableEditStatement.rename(
            [SQLRenamePair(from: Self.name(Self.bare("a")), to: Self.name(Self.bare("b")))], kind: .table
        )
        #expect(try Self.parse("ALTER TABLE a RENAME AS b", .mysql) == expected)
        #expect(try Self.parse("ALTER TABLE a RENAME b", .mysql) == expected)
        #expect(try Self.parse("ALTER TABLE a RENAME b", .postgresql) == .other)
    }

    @Test("A column, index or constraint rename is not a table rename")
    func columnRenamesAreNotRead() throws {
        #expect(try Self.parse("ALTER TABLE a RENAME COLUMN x TO y", .postgresql) == .other)
        #expect(try Self.parse("ALTER TABLE a RENAME x TO y", .postgresql) == .other)
        #expect(try Self.parse("ALTER TABLE a RENAME x TO y", .sqlite) == .other)
        #expect(try Self.parse("ALTER TABLE a RENAME INDEX i TO j", .mysql) == .other)
        #expect(try Self.parse("ALTER TABLE a RENAME CONSTRAINT c TO d", .postgresql) == .other)
        #expect(try Self.parse("ALTER TABLE a RENAME TO b, ADD COLUMN c INT", .mysql) == .other)
    }

    @Test("RENAME TABLE reads every pair in order")
    func renameTablePairs() throws {
        #expect(
            try Self.parse("RENAME TABLE a TO tmp, b TO a, tmp TO b", .mysql)
                == .rename(
                    [
                        SQLRenamePair(from: Self.name(Self.bare("a")), to: Self.name(Self.bare("tmp"))),
                        SQLRenamePair(from: Self.name(Self.bare("b")), to: Self.name(Self.bare("a"))),
                        SQLRenamePair(from: Self.name(Self.bare("tmp")), to: Self.name(Self.bare("b")))
                    ],
                    kind: .table
                )
        )
        #expect(
            try Self.parse("RENAME TABLE db.a TO db.b ON CLUSTER main", .clickhouse)
                == .rename(
                    [SQLRenamePair(from: Self.name(Self.bare("db"), Self.bare("a")), to: Self.name(Self.bare("db"), Self.bare("b")))],
                    kind: .table
                )
        )
    }

    @Test("RENAME USER and Oracle's keyword-less RENAME are not read")
    func otherRenames() throws {
        #expect(try Self.parse("RENAME USER 'a'@'h' TO 'b'@'h'", .mysql) == .other)
        #expect(try Self.parse("RENAME emp TO staff", .oracle) == .other)
    }

    // MARK: - Transactions and context

    @Test("Transaction control is read the way each engine writes it")
    func transactionControl() throws {
        #expect(try Self.parse("BEGIN", .postgresql) == .beginsTransaction)
        #expect(try Self.parse("START TRANSACTION", .mysql) == .beginsTransaction)
        #expect(try Self.parse("BEGIN TRAN", .mssql) == .beginsTransaction)
        #expect(try Self.parse("BEGIN TRY", .mssql) == .controlsFlow)
        #expect(try Self.parse("BEGIN IMMEDIATE", .sqlite) == .beginsTransaction)
        #expect(try Self.parse("BEGIN NULL; END", .oracle) == .runsUnseenCode)
        #expect(try Self.parse("COMMIT", .postgresql) == .commits)
        #expect(try Self.parse("END", .postgresql) == .commits)
        #expect(try Self.parse("END", .mssql) == .other)
        #expect(try Self.parse("ROLLBACK", .postgresql) == .rollsBack)
        #expect(try Self.parse("ABORT", .postgresql) == .rollsBack)
        #expect(try Self.parse("ROLLBACK TO SAVEPOINT s", .postgresql) == .rollsBackToSavepoint)
        #expect(try Self.parse("ROLLBACK TRAN s", .mssql) == .rollsBackToSavepoint)
        #expect(try Self.parse("ROLLBACK AND NO CHAIN", .mysql) == .rollsBack)
        #expect(try Self.parse("COMMIT AND CHAIN", .mysql) == .losesTransactionTracking)
        #expect(try Self.parse("COMMIT PREPARED 'x'", .postgresql) == .other)
        #expect(try Self.parse("PREPARE TRANSACTION 'x'", .postgresql) == .losesTransactionTracking)
        #expect(try Self.parse("SAVEPOINT s", .sqlite) == .beginsTransaction)
        #expect(try Self.parse("RELEASE s", .sqlite) == .commits)
        #expect(try Self.parse("SET IMPLICIT_TRANSACTIONS ON", .mssql) == .losesTransactionTracking)
        #expect(try Self.parse("SET ANSI_NULLS, IMPLICIT_TRANSACTIONS ON", .mssql) == .losesTransactionTracking)
    }

    /// SQL Server runs a batch whole, so a statement after one of these may never have run.
    @Test("T-SQL control flow is read as such, and only on SQL Server")
    func sqlServerControlFlow() throws {
        for sql in [
            "IF OBJECT_ID('dbo.people') IS NOT NULL DROP TABLE dbo.people",
            "ELSE SELECT 1",
            "WHILE @i < 3 SET @i += 1",
            "GOTO done",
            "RETURN",
            "BREAK",
            "done: SELECT 1",
            "BEGIN TRY DROP TABLE dbo.people",
            "END TRY BEGIN CATCH SELECT 1",
            "END CATCH"
        ] {
            #expect(try Self.parse(sql, .mssql) == .controlsFlow, "\(sql)")
        }
        #expect(try Self.parse("BEGIN TRANSACTION", .mssql) == .beginsTransaction)
        #expect(try Self.parse("SELECT :id FROM dual", .oracle) == .other)
        #expect(try Self.parse("IF 1 = 1 THEN SELECT 1", .mysql) == .other)
        #expect(try Self.parse("END TRY", .postgresql) == .commits)
    }

    @Test("A statement that moves where a bare name points is read as doing so")
    func nameContext() throws {
        #expect(try Self.parse("USE `archive`", .mysql) == .selectsDatabase(Self.name(Self.quoted("archive"))))
        #expect(try Self.parse("SET search_path TO app, public", .postgresql) == .losesSchemaContext)
        #expect(try Self.parse("SET LOCAL search_path = app", .postgresql) == .losesSchemaContext)
        #expect(try Self.parse("RESET ALL", .postgresql) == .losesSchemaContext)
        #expect(try Self.parse("ALTER SESSION SET CURRENT_SCHEMA = hr", .oracle) == .losesSchemaContext)
        #expect(try Self.parse("EXECUTE AS USER = 'x'", .mssql) == .losesSchemaContext)
        #expect(try Self.parse("SET NAMES utf8mb4", .mysql) == .other)
    }

    @Test("A temporary table's creation is read with its name")
    func temporaryTableCreation() throws {
        #expect(
            try Self.parse("CREATE VIRTUAL TABLE temp.people USING fts5(body)", .sqlite)
                == .createsTemporaryTable(Self.name(Self.bare("temp"), Self.bare("people")))
        )
        #expect(try Self.parse("CREATE VIRTUAL TABLE people USING fts5(body)", .sqlite) == .other)
        #expect(
            try Self.parse("CREATE TEMPORARY TABLE IF NOT EXISTS people (id int)", .mysql)
                == .createsTemporaryTable(Self.name(Self.bare("people")))
        )
        #expect(
            try Self.parse("CREATE TEMP TABLE people AS SELECT 1", .postgresql)
                == .createsTemporaryTable(Self.name(Self.bare("people")))
        )
        #expect(
            try Self.parse("CREATE OR REPLACE TEMP VIEW recent AS SELECT 1", .postgresql)
                == .createsTemporaryTable(Self.name(Self.bare("recent")))
        )
        #expect(
            try Self.parse("CREATE TABLE temp.people (id int)", .sqlite)
                == .createsTemporaryTable(Self.name(Self.bare("temp"), Self.bare("people")))
        )
        #expect(
            try Self.parse("CREATE TABLE pg_temp.people (id int)", .postgresql)
                == .createsTemporaryTable(Self.name(Self.bare("pg_temp"), Self.bare("people")))
        )
        #expect(try Self.parse("CREATE TABLE people (id int)", .postgresql) == .other)
        #expect(try Self.parse("CREATE TABLE archive.people (id int)", .sqlite) == .other)
        #expect(try Self.parse("CREATE OR REPLACE VIEW v AS SELECT 1", .postgresql) == .other)
    }

    @Test("A procedure, a prepared statement or an anonymous block is code the text does not show")
    func unseenCode() throws {
        #expect(try Self.parse("CALL rebuild_people()", .mysql) == .runsUnseenCode)
        #expect(try Self.parse("DO $$ BEGIN CREATE TEMP TABLE t (id int); END $$", .postgresql) == .runsUnseenCode)
        #expect(try Self.parse("EXECUTE make_temp", .postgresql) == .runsUnseenCode)
        #expect(try Self.parse("EXEC dbo.load_staging", .mssql) == .runsUnseenCode)
        #expect(try Self.parse("EXEC('DROP TABLE dbo.t')", .mssql) == .runsUnseenCode)
        #expect(try Self.parse("BEGIN NOT ATOMIC CREATE TEMPORARY TABLE t (id int); END", .mariadb) == .runsUnseenCode)
        #expect(try Self.parse("DECLARE n NUMBER; BEGIN NULL; END", .oracle) == .runsUnseenCode)
        #expect(try Self.parse("DECLARE @n int", .mssql) == .other)
    }

    @Test("Only a drop or a rename edits a table, and only what moves where a name points is a hazard")
    func statementKinds() throws {
        #expect(try Self.parse("DROP TABLE t", .postgresql).editsTable)
        #expect(try Self.parse("ALTER TABLE t RENAME TO u", .postgresql).editsTable)
        #expect(try !Self.parse("SELECT * FROM t", .postgresql).editsTable)
        #expect(try !Self.parse("BEGIN", .postgresql).editsTable)
        #expect(try Self.parse("CREATE TEMP TABLE t (id int)", .postgresql).changesNameHazards)
        #expect(try Self.parse("SET search_path TO app", .postgresql).changesNameHazards)
        #expect(try Self.parse("CALL p()", .mysql).changesNameHazards)
        #expect(try !Self.parse("DROP TEMPORARY TABLE t", .mysql).changesNameHazards)
        #expect(try !Self.parse("DROP TABLE t", .postgresql).changesNameHazards)
    }
}

struct TableEditDialectTests {
    private static func part(_ text: String, quoted: Bool = false) -> SQLNamePart {
        SQLNamePart(text: text, isQuoted: quoted)
    }

    private static let context = TableNameContext(database: "shop", schema: "public")

    @Test("Engines with a dialect the app knows are covered, and the rest are not")
    func coverage() {
        for type in [DatabaseType.mysql, .mariadb, .postgresql, .redshift, .sqlite, .mssql, .oracle, .clickhouse, .duckdb] {
            #expect(TableEditDialect.of(type) != nil, "\(type.rawValue) should be covered")
        }
        for type in [DatabaseType.cockroachdb, .snowflake, .mongodb, .redis, .bigQuery, .trino, .cassandra] {
            #expect(TableEditDialect.of(type) == nil, "\(type.rawValue) should be left alone")
        }
    }

    @Test("PostgreSQL folds a bare word to lowercase, keeps a quoted one as written, and places no bare name")
    func postgresFolding() {
        let dialect = TableEditDialect.postgreSQL
        #expect(dialect.resolve(SQLObjectName(parts: [Self.part("People")]), in: Self.context) == nil)
        #expect(
            dialect.resolve(SQLObjectName(parts: [Self.part("public"), Self.part("People", quoted: true)]), in: Self.context)
                == TablePlacement(database: "shop", schema: "public", name: "People")
        )
        #expect(
            dialect.resolve(SQLObjectName(parts: [Self.part("Sales"), Self.part("Orders")]), in: Self.context)
                == TablePlacement(database: "shop", schema: "sales", name: "orders")
        )
        #expect(
            dialect.resolve(SQLObjectName(parts: [Self.part("shop"), Self.part("app"), Self.part("t")]), in: Self.context)
                == TablePlacement(database: "shop", schema: "app", name: "t")
        )
    }

    @Test("Oracle folds a bare name to uppercase")
    func oracleFolding() {
        let context = TableNameContext(database: "ORCL", schema: "HR")
        #expect(
            TableEditDialect.oracle.resolve(SQLObjectName(parts: [Self.part("emp")]), in: context)
                == TablePlacement(database: "ORCL", schema: "HR", name: "EMP")
        )
    }

    @Test("A bare word with letters outside ASCII is left unplaced where the engine folds case")
    func nonASCIIFoldingIsUnsure() {
        let unquoted = SQLObjectName(parts: [Self.part("public"), Self.part("Ärger")])
        let quoted = SQLObjectName(parts: [Self.part("public"), Self.part("Ärger", quoted: true)])
        #expect(TableEditDialect.postgreSQL.resolve(unquoted, in: Self.context) == nil)
        #expect(
            TableEditDialect.postgreSQL.resolve(quoted, in: Self.context)
                == TablePlacement(database: "shop", schema: "public", name: "Ärger")
        )
        #expect(
            TableEditDialect.mySQL.resolve(SQLObjectName(parts: [Self.part("Ärger")]), in: TableNameContext(database: "shop"))
                == TablePlacement(database: "shop", schema: nil, name: "Ärger")
        )
    }

    @Test("MySQL qualifies by database and keys no schema")
    func mySQLQualification() {
        let context = TableNameContext(database: "shop", schema: nil)
        #expect(
            TableEditDialect.mySQL.resolve(SQLObjectName(parts: [Self.part("Orders")]), in: context)
                == TablePlacement(database: "shop", schema: nil, name: "Orders")
        )
        #expect(
            TableEditDialect.mySQL.resolve(SQLObjectName(parts: [Self.part("archive"), Self.part("Orders")]), in: context)
                == TablePlacement(database: "archive", schema: nil, name: "Orders")
        )
        #expect(TableEditDialect.mySQL.resolve(SQLObjectName(parts: [Self.part("a"), Self.part("b"), Self.part("c")]), in: context) == nil)
    }

    @Test("SQL Server places only a qualified name, because a bare one follows the login's default schema")
    func sqlServerNeedsQualification() {
        let context = TableNameContext(database: "sales", schema: "reporting")
        #expect(TableEditDialect.sqlServer.resolve(SQLObjectName(parts: [Self.part("t")]), in: context) == nil)
        #expect(
            TableEditDialect.sqlServer.resolve(SQLObjectName(parts: [Self.part("dbo"), Self.part("t")]), in: context)
                == TablePlacement(database: "sales", schema: "dbo", name: "t")
        )
    }

    @Test("A two-part name is not placed where the engine reads it more than one way")
    func ambiguousTwoPartNames() {
        let name = SQLObjectName(parts: [Self.part("aux"), Self.part("t")])
        #expect(TableEditDialect.duckDB.resolve(name, in: Self.context) == nil)
        #expect(TableEditDialect.sqlite.resolve(name, in: TableNameContext(database: "/tmp/app.db", schema: nil)) == nil)
    }

    @Test("A bare name has no place once the context it resolves in is unknown")
    func unknownContext() {
        #expect(
            TableEditDialect.oracle.resolve(
                SQLObjectName(parts: [Self.part("t")]), in: TableNameContext(database: "ORCL", schema: nil)
            ) == nil
        )
        #expect(
            TableEditDialect.mySQL.resolve(SQLObjectName(parts: [Self.part("t")]), in: TableNameContext(database: nil)) == nil
        )
    }

    @Test("USE moves the database only where a single name selects one")
    func useContext() {
        let archive = SQLObjectName(parts: [Self.part("archive")])
        #expect(TableEditDialect.mySQL.context(afterUsing: archive) == TableNameContext(database: "archive", schema: nil))
        #expect(TableEditDialect.duckDB.context(afterUsing: archive) == TableNameContext(database: nil, schema: nil))
        #expect(TableEditDialect.mySQL.context(afterUsing: nil) == TableNameContext(database: nil, schema: nil))
    }
}
