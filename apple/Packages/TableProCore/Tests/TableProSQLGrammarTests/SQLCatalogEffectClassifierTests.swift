import Foundation
import TableProSQLGrammar
import Testing

struct SQLCatalogEffectClassifierTests {
    private func grammar(_ engine: String) -> SQLLexicalGrammar {
        SQLLexicalReadings.resolve(databaseTypeId: engine, declared: nil, session: nil).execution
    }

    private func kinds(_ sql: String, _ engine: String = "PostgreSQL") -> SQLCatalogObjectKinds {
        SQLCatalogEffectClassifier.effect(of: sql, grammar: grammar(engine)).kinds
    }

    @Test("Definitions name the kinds they change")
    func definitions() {
        #expect(kinds("CREATE TABLE t (id int)") == .tables)
        #expect(kinds("drop view v") == .tables)
        #expect(kinds("CREATE OR REPLACE FUNCTION f() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql") == .routines)
        #expect(kinds("DROP SCHEMA sales CASCADE") == [.schemas, .objects])
        #expect(kinds("CREATE DATABASE shop", "MySQL") == .everything)
        #expect(kinds("CREATE TABLE copy AS SELECT * FROM t") == .tables)
    }

    @Test("Row work and reads leave the catalog alone, except SELECT INTO")
    func rowsAndReads() {
        #expect(kinds("INSERT INTO t VALUES (1)").isEmpty)
        #expect(kinds("UPDATE t SET a = 1").isEmpty)
        #expect(kinds("SELECT * FROM t").isEmpty)
        #expect(kinds("SELECT * INTO archive FROM t", "SQL Server") == .tables)
        #expect(kinds("-- note\nSELECT comment FROM t").isEmpty)
    }

    @Test("DISCARD TEMP and DISCARD ALL drop the session's temporary tables, other DISCARDs change nothing")
    func discardDropsTemporaryTables() {
        #expect(kinds("DISCARD TEMP") == .tables)
        #expect(kinds("discard temporary") == .tables)
        #expect(kinds("DISCARD ALL") == .tables)
        #expect(kinds("DISCARD PLANS").isEmpty)
        #expect(kinds("DISCARD SEQUENCES").isEmpty)
    }

    @Test("Ending a transaction is reported, a rollback to a savepoint is not")
    func transactionEnds() {
        #expect(SQLCatalogEffectClassifier.effect(of: "COMMIT", grammar: grammar("PostgreSQL")).endsTransaction)
        #expect(SQLCatalogEffectClassifier.effect(of: "rollback", grammar: grammar("MySQL")).endsTransaction)
        #expect(SQLCatalogEffectClassifier.effect(of: "ROLLBACK TO SAVEPOINT a", grammar: grammar("PostgreSQL")) == .none)
        #expect(SQLCatalogEffectClassifier.effect(of: "BEGIN", grammar: grammar("PostgreSQL")) == .none)
    }

    @Test("Code the text cannot show refreshes every kind")
    func opaqueCode() {
        #expect(kinds("DO $$ BEGIN EXECUTE 'CREATE TABLE t (id int)'; END $$") == .everything)
        #expect(kinds("BEGIN EXECUTE IMMEDIATE 'DROP TABLE t'; END;", "Oracle") == .everything)
        #expect(kinds("CALL make_tables()") == .everything)
        #expect(kinds("SET NOCOUNT ON; EXEC dbo.rebuild", "SQL Server") == .everything)
    }

    @Test("A MySQL executable comment is read as the code it is")
    func executableComment() {
        #expect(kinds("/*!50001 CREATE ALGORITHM=UNDEFINED VIEW v AS SELECT 1 */", "MySQL") == .tables)
    }

    @Test("SQL Server finds a definition past the batch's first command")
    func embeddedDefinition() {
        #expect(kinds("SET NOCOUNT ON\nCREATE TABLE t (id int)", "SQL Server") == .tables)
    }

    @Test("Several statements combine their effects")
    func combined() {
        let effect = SQLCatalogEffectClassifier.effect(
            ofStatements: ["INSERT INTO t VALUES (1)", "CREATE INDEX i ON t (a)", "COMMIT"],
            grammar: grammar("PostgreSQL")
        )
        #expect(effect.kinds == .tables)
        #expect(effect.endsTransaction)
    }

    @Test("Leading comments are skipped, a MySQL executable comment is kept")
    func leadingComments() {
        #expect(SQLLeadingComments.stripping("-- a\n/* b */ SELECT 1") == "SELECT 1")
        #expect(SQLLeadingComments.stripping("/*!40101 SET x = 1 */") == "/*!40101 SET x = 1 */")
        #expect(SQLLeadingComments.stripping("-- only a comment").isEmpty)
    }

    @Test("A procedure or block runs statements the text does not show; database DDL refreshes as much but says what it does")
    func unseenStatementsAreMarked() {
        let mysql = grammar("MySQL")
        #expect(SQLCatalogEffectClassifier.effect(of: "CALL make_scratch()", grammar: mysql).runsUnseenStatements)
        let database = SQLCatalogEffectClassifier.effect(of: "CREATE DATABASE archive", grammar: mysql)
        #expect(!database.runsUnseenStatements)
        #expect(!SQLCatalogEffectClassifier.effect(ofStatements: ["SELECT 1", "DROP DATABASE archive"], grammar: mysql)
            .runsUnseenStatements)
    }
}
