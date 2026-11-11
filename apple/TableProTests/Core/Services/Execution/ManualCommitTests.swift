//
//  ManualCommitTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSSHConfig
import Testing

struct ManualCommitTests {
    private func decision(
        _ sql: String,
        mode: ConnectionCommitMode = .manual,
        type: DatabaseType = .postgresql,
        supportsTransactions: Bool = true,
        state: PluginSessionTransactionState = .idle
    ) -> ManualCommit.Decision {
        decision([sql], mode: mode, type: type, supportsTransactions: supportsTransactions, state: state)
    }

    private func decision(
        _ statements: [String],
        mode: ConnectionCommitMode = .manual,
        type: DatabaseType = .postgresql,
        supportsTransactions: Bool = true,
        state: PluginSessionTransactionState = .idle
    ) -> ManualCommit.Decision {
        ManualCommit.decision(
            commitMode: mode,
            statements: statements,
            databaseType: type,
            grammar: type.lexicalGrammar,
            supportsTransactions: supportsTransactions,
            sessionState: state
        )
    }

    @Test("A write on an idle session is held in Manual Commit and runs as typed otherwise")
    func writeOnAnIdleSessionIsHeld() {
        #expect(decision("UPDATE t SET a = 1") == .hold)
        #expect(decision("UPDATE t SET a = 1", mode: .automatic) == .runAsIs)
    }

    @Test("A read opens nothing")
    func readOpensNothing() {
        #expect(decision("SELECT * FROM t") == .runAsIs)
    }

    @Test("A write joins a transaction already open, aborted or not")
    func writeJoinsAnOpenTransaction() {
        #expect(decision("UPDATE t SET a = 1", state: .inTransaction) == .runAsIs)
        #expect(decision("UPDATE t SET a = 1", state: .abortedTransaction) == .runAsIs)
    }

    @Test(
        "A write the session cannot hold is refused rather than committed",
        arguments: [PluginSessionTransactionState.unknown, .holdsSessionLocks]
    )
    func unholdableStateRefuses(state: PluginSessionTransactionState) {
        #expect(decision("UPDATE t SET a = 1", state: state) == .refuse)
    }

    @Test("An engine without transactions refuses a write in Manual Commit")
    func engineWithoutTransactionsRefuses() {
        #expect(decision("UPDATE t SET a = 1", supportsTransactions: false) == .refuse)
        #expect(decision("SELECT 1", supportsTransactions: false) == .runAsIs)
    }

    @Test("Transaction control and statements refused inside a block run as typed")
    func transactionControlAndAutocommitOnlyRunAsTyped() {
        #expect(decision("BEGIN") == .runAsIs)
        #expect(decision("VACUUM") == .runAsIs)
    }

    @Test("DDL on an engine that commits it implicitly ends the open transaction, elsewhere it does not")
    func implicitCommitDDL() {
        let mysql = DatabaseType.mysql
        #expect(ManualCommit.commitsHeldTransaction(["ALTER TABLE t ADD c INT"], databaseType: mysql, grammar: mysql.lexicalGrammar))
        #expect(ManualCommit.commitsHeldTransaction(["TRUNCATE TABLE t"], databaseType: mysql, grammar: mysql.lexicalGrammar))
        #expect(!ManualCommit.commitsHeldTransaction(["UPDATE t SET a = 1"], databaseType: mysql, grammar: mysql.lexicalGrammar))
        let postgres = DatabaseType.postgresql
        #expect(!ManualCommit.commitsHeldTransaction(
            ["ALTER TABLE t ADD c INT"], databaseType: postgres, grammar: postgres.lexicalGrammar
        ))
    }

    @Test("A run that mixes a write with a statement that can't run inside a transaction is refused")
    func autocommitOnlyBesideAWriteRefuses() {
        #expect(decision(["UPDATE t SET a = 1", "VACUUM t"]) == .refuseMixed)
        #expect(decision(["DELETE FROM t", "CREATE INDEX CONCURRENTLY i ON t (a)"]) == .refuseMixed)
        #expect(decision(["VACUUM t"]) == .runAsIs)
    }

    @Test("On MySQL a run that mixes a write with DDL is refused, and DDL alone runs as typed")
    func implicitCommitBesideAWriteRefuses() {
        #expect(decision(["UPDATE t SET a = 1", "ALTER TABLE u ADD c INT"], type: .mysql) == .refuseMixed)
        #expect(decision(["ALTER TABLE u ADD c INT"], type: .mysql) == .runAsIs)
        #expect(decision(["UPDATE t SET a = 1", "ALTER TABLE u ADD c INT"], type: .postgresql) == .hold)
    }

    @Test("Two reads in Manual Commit are not held: the run keeps the plan an automatic connection uses")
    func readOnlyRunIsNotHeld() {
        let reads = ["SELECT 1", "SELECT 2"]
        let decided = decision(reads)
        #expect(decided == .runAsIs)
        #expect(ManualCommit.runPlan(text: .appTransaction, decision: decided, sessionState: .idle) == .appTransaction)
        #expect(ManualCommit.runPlan(text: .appTransaction, decision: .hold, sessionState: .idle) == .heldTransaction)
        #expect(ManualCommit.runPlan(text: .autocommit, decision: .runAsIs, sessionState: .inTransaction) == .sessionTransaction)
    }

    @Test("An EXPLAIN ANALYZE of a write is held like the write")
    func explainAnalyzeOfAWriteIsHeld() {
        #expect(decision("EXPLAIN ANALYZE DELETE FROM orders WHERE id = 1") == .hold)
        #expect(decision("EXPLAIN SELECT * FROM orders") == .runAsIs)
    }

    @Test("A read that timed out after the turn's own BEGIN records the hold it opened")
    func timedOutReadAfterTheTurnsBeginIsOpen() {
        #expect(ManualCommit.recordedState(read: .unknown, turnOpenedHold: true) == .inTransaction)
        #expect(ManualCommit.recordedState(read: .unknown, turnOpenedHold: false) == .unknown)
        #expect(ManualCommit.recordedState(read: .idle, turnOpenedHold: true) == .idle)
    }

    @Test("COMMIT, ROLLBACK, BEGIN, SAVEPOINT and END control the transaction; a PL/SQL block does not")
    func transactionControlIsRecognised() {
        let postgres = DatabaseType.postgresql
        for sql in ["COMMIT", "ROLLBACK", "ROLLBACK TO SAVEPOINT a", "BEGIN", "START TRANSACTION", "SAVEPOINT a", "END"] {
            #expect(ManualCommit.controlsTransaction([sql], databaseType: postgres, grammar: postgres.lexicalGrammar), "\(sql)")
        }
        #expect(!ManualCommit.controlsTransaction(["UPDATE t SET a = 1"], databaseType: postgres, grammar: postgres.lexicalGrammar))
        let oracle = DatabaseType.oracle
        #expect(!ManualCommit.controlsTransaction(
            ["BEGIN UPDATE t SET a = 1; END;"], databaseType: oracle, grammar: oracle.lexicalGrammar
        ))
    }

    @Test("Over an open transaction, an agent statement takes a savepoint where one exists and is refused where none does")
    func agentProtectionFollowsTheFamily() {
        #expect(AgentTransactionGuard.protection(family: .postgres, sessionState: .inTransaction, controlsTransaction: false) == .savepoint)
        #expect(AgentTransactionGuard.protection(family: .cockroach, sessionState: .inTransaction, controlsTransaction: false) == .savepoint)
        #expect(AgentTransactionGuard.protection(family: .duckdb, sessionState: .inTransaction, controlsTransaction: false) == .refuse)
        #expect(AgentTransactionGuard.protection(family: .redshift, sessionState: .inTransaction, controlsTransaction: false) == .refuse)
        #expect(AgentTransactionGuard.protection(family: .mysql, sessionState: .inTransaction, controlsTransaction: false) == .none)
        #expect(AgentTransactionGuard.protection(family: .postgres, sessionState: .idle, controlsTransaction: false) == .none)
        #expect(AgentTransactionGuard.protection(family: .postgres, sessionState: .inTransaction, controlsTransaction: true) == .none)
    }

    @Test("Unseen transaction control: a T-SQL COMMIT inside a batch, an IF, a procedure call")
    func unseenTransactionControlIsRecognised() {
        let mssql = DatabaseType.mssql
        for sql in ["UPDATE t SET a = 1 COMMIT", "IF @@TRANCOUNT > 0 ROLLBACK", "EXEC dbo.p", "SAVE TRAN s"] {
            #expect(ManualCommit.mayEndTransactionUnseen([sql], databaseType: mssql, grammar: mssql.lexicalGrammar), "\(sql)")
        }
        let mysql = DatabaseType.mysql
        #expect(ManualCommit.mayEndTransactionUnseen(["CALL p()"], databaseType: mysql, grammar: mysql.lexicalGrammar))
        for sql in ["UPDATE t SET a = CASE WHEN b = 1 THEN 1 ELSE 2 END", "SELECT 'commit'", "UPDATE t SET a = 1"] {
            #expect(!ManualCommit.mayEndTransactionUnseen([sql], databaseType: mysql, grammar: mysql.lexicalGrammar), "\(sql)")
        }
    }

    @Test("The editor never offers Commit and Run for a run Manual Commit refuses")
    func noPromptForARefusedRun() {
        let mysql = DatabaseType.mysql
        let mixed = ["UPDATE a SET x = 1", "ALTER TABLE b ADD c INT"]
        #expect(!ManualCommit.asksBeforeImplicitCommit(mixed, databaseType: mysql, grammar: mysql.lexicalGrammar, commitMode: .manual))
        #expect(ManualCommit.asksBeforeImplicitCommit(mixed, databaseType: mysql, grammar: mysql.lexicalGrammar, commitMode: .automatic))
        #expect(ManualCommit.asksBeforeImplicitCommit(
            ["ALTER TABLE b ADD c INT"], databaseType: mysql, grammar: mysql.lexicalGrammar, commitMode: .manual
        ))
        #expect(!ManualCommit.asksBeforeImplicitCommit(
            ["UPDATE a SET x = 1"], databaseType: mysql, grammar: mysql.lexicalGrammar, commitMode: .automatic
        ))
    }

    @Test("A reply says the transaction ended when it did, and that a held change is pending otherwise")
    func agentNoticeFollowsTheEndState() {
        #expect(AgentTransactionGuard.notice(startState: .inTransaction, endState: .idle, pendingMatters: true)
            == ManualCommit.transactionEndedNotice)
        #expect(AgentTransactionGuard.notice(startState: .inTransaction, endState: .idle, pendingMatters: false)
            == ManualCommit.transactionEndedNotice)
        #expect(AgentTransactionGuard.notice(startState: .idle, endState: .inTransaction, pendingMatters: true)
            == ManualCommit.pendingNotice)
        #expect(AgentTransactionGuard.notice(startState: .inTransaction, endState: .inTransaction, pendingMatters: false) == nil)
    }

    @Test("The refusal says how to run the change")
    func refusalNamesTheWayOut() {
        #expect(
            ManualCommitRefusal().errorDescription
                == "This connection can't hold this change until you commit, so it did not run. Turn off Manual Commit in the Database menu to run it."
        )
        #expect(ManualCommit.Decision.refuseMixed.refusal?.localizedDescription == ManualCommitMixedRefusal().errorDescription)
    }
}

struct ConnectionCommitModeStorageTests {
    @Test("Manual Commit round-trips through the connection's fields, and Automatic removes the key")
    func commitModeRoundTrips() {
        var connection = TestFixtures.makeConnection(type: .postgresql)
        #expect(connection.commitMode == .automatic)
        #expect(connection.additionalFields[DatabaseConnection.commitModeKey] == nil)

        connection.commitMode = .manual
        #expect(connection.additionalFields[DatabaseConnection.commitModeKey] == "manual")
        #expect(connection.commitMode == .manual)

        connection.commitMode = .automatic
        #expect(connection.additionalFields[DatabaseConnection.commitModeKey] == nil)
    }

    @Test("A session starts in the connection's commit mode")
    func sessionSeedsFromTheConnection() {
        var connection = TestFixtures.makeConnection(type: .postgresql)
        connection.commitMode = .manual
        #expect(ConnectionSession(connection: connection).commitMode == .manual)
    }

    @Test("The form writes Manual Commit into the saved fields, and turning it off removes the key")
    func formEditsCarryTheMode() {
        var base = TestFixtures.makeConnection(type: .postgresql)
        base.commitMode = .manual
        #expect(ConnectionFormEditsSample.edits(commitMode: .automatic).applied(to: base).commitMode == .automatic)
        let saved = ConnectionFormEditsSample.edits(commitMode: .manual).applied(to: TestFixtures.makeConnection())
        #expect(saved.additionalFields[DatabaseConnection.commitModeKey] == "manual")
    }
}

private enum ConnectionFormEditsSample {
    static func edits(commitMode: ConnectionCommitMode) -> ConnectionFormEdits {
        ConnectionFormEdits(
            name: "Edited",
            host: "db.example.com",
            port: 6_000,
            database: "edited_db",
            username: "edited_user",
            type: .postgresql,
            sshConfig: SSHConfiguration(),
            sslConfig: SSLConfiguration(),
            color: .blue,
            iconName: nil,
            tagIds: [],
            groupId: nil,
            sshProfileId: nil,
            sshTunnelMode: .disabled,
            credentialMode: .inline,
            cloudflareTunnelMode: .disabled,
            cloudSQLProxyMode: .disabled,
            socksProxyMode: .disabled,
            tunnelCommandMode: .disabled,
            safeModeLevel: .silent,
            aiPolicy: nil,
            aiRules: nil,
            externalAccess: .readOnly,
            commitMode: commitMode,
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: false,
            additionalFields: [:],
            ownedAdditionalFieldIDs: ConnectionFormEdits.appManagedAdditionalFieldIDs
        )
    }
}
