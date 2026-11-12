//
//  ManualCommit.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar
import TableProUtilities

// A refusal an external caller reads as it is: it quotes nothing the server said.
internal protocol ManualCommitRefusing: LocalizedError {}

internal struct ManualCommitRefusal: ManualCommitRefusing, Equatable {
    var errorDescription: String? {
        String(
            localized: "This connection can't hold this change until you commit, so it did not run. Turn off Manual Commit in the Database menu to run it."
        )
    }
}

internal struct ManualCommitMixedRefusal: ManualCommitRefusing, Equatable {
    var errorDescription: String? {
        String(
            localized: "This run mixes changes with a statement that can't run in a transaction. Run that statement on its own, or turn off Manual Commit."
        )
    }
}

internal struct ManualCommitSessionOptionsRefusal: ManualCommitRefusing, Equatable {
    var errorDescription: String? {
        String(
            localized: "This change sets session options around its statements, so it can't wait for Commit. Turn off Manual Commit in the Database menu to run it."
        )
    }
}

internal struct ManualCommitForeignKeyRefusal: ManualCommitRefusing, Equatable {
    var errorDescription: String? {
        String(
            localized: "This import turns off foreign key checks, which can't wait for Commit. Turn off Disable foreign key checks or Manual Commit to run it."
        )
    }
}

internal struct ManualCommitUnwrappedImportRefusal: ManualCommitRefusing, Equatable {
    var errorDescription: String? {
        String(
            localized: "This import runs each statement on its own, so nothing can wait for Commit. Turn on Wrap in transaction or turn off Manual Commit."
        )
    }
}

internal struct ManualCommitTransactionControlRefusal: ManualCommitRefusing, Equatable {
    var errorDescription: String? { ManualCommit.transactionControlRefusalMessage }
}

internal struct OpenTransactionRefusal: ManualCommitRefusing, Equatable {
    var errorDescription: String? { ManualCommit.openTransactionRefusalMessage }
}

internal struct AbortingTransactionRefusal: ManualCommitRefusing, Equatable {
    var errorDescription: String? {
        String(
            localized: "A transaction is open on this connection, and a failed statement would abort it. Commit or roll back in TablePro first."
        )
    }
}

// Set by `openIfNeeded` for the session turn it runs in, so the turn records the hold its BEGIN opened.
internal final class ManualCommitTurnHold: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false

    var isHeld: Bool { lock.withLock { held } }

    func mark(_ value: Bool) {
        lock.withLock { held = value }
    }
}

// One statement's run under its connection's commit mode, read on the main actor before the lease.
internal struct ManualCommitRun: Sendable {
    let commitMode: ConnectionCommitMode
    let databaseType: DatabaseType
    let grammar: SQLLexicalGrammar
    let connectionId: UUID

    nonisolated func running<T>(
        _ statements: [String],
        on driver: DatabaseDriver,
        _ body: () async throws -> T
    ) async throws -> T {
        let opened = try await ManualCommit.openIfNeeded(
            on: driver, statements: statements, databaseType: databaseType, grammar: grammar, commitMode: commitMode
        )
        do {
            return try await body()
        } catch {
            if opened { await ManualCommit.rollBackOpened(on: driver, connectionId: connectionId) }
            throw error
        }
    }
}

// The hold a Manual Commit connection opens before the first write the user or an agent sends: BEGIN, never COMMIT.
internal enum ManualCommit {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ManualCommit")

    @TaskLocal internal static var turnHold: ManualCommitTurnHold?

    internal enum Decision: Equatable {
        case runAsIs
        case hold
        case refuse
        case refuseMixed

        var refusal: (any Error)? {
            switch self {
            case .runAsIs, .hold: return nil
            case .refuse: return ManualCommitRefusal()
            case .refuseMixed: return ManualCommitMixedRefusal()
            }
        }
    }

    // These commit schema and maintenance statements on their own, so nothing can wait there; Redshift's TRUNCATE
    // and CockroachDB's DDL commit the open transaction too.
    nonisolated internal static func isAvailable(for databaseType: DatabaseType) -> Bool {
        guard TableEditDialect.of(databaseType)?.commitsDDLImplicitly != true else { return false }
        let family = TransactionEngineFamily.of(databaseType)
        return family != .redshift && family != .cockroach
    }

    nonisolated internal static func effectiveMode(
        _ stored: ConnectionCommitMode,
        databaseType: DatabaseType
    ) -> ConnectionCommitMode {
        isAvailable(for: databaseType) ? stored : .automatic
    }

    internal static var unavailableExplanation: String {
        String(localized: "This database commits schema and maintenance statements on its own, so changes can't wait for Commit.")
    }

    // Exactly `.idle` holds: `.unknown` and a table lock would let the write commit on its own.
    nonisolated internal static func decision(
        commitMode: ConnectionCommitMode,
        statements: [String],
        databaseType: DatabaseType,
        grammar: SQLLexicalGrammar,
        supportsTransactions: Bool,
        sessionState: PluginSessionTransactionState
    ) -> Decision {
        guard commitMode == .manual, writes(statements, databaseType: databaseType) else { return .runAsIs }
        let family = TransactionEngineFamily.of(databaseType)
        guard supportsTransactions, family.wrapsBatchInTransaction else { return .refuse }
        switch BatchTransactionPolicy.plan(for: statements, databaseType: databaseType, grammar: grammar) {
        case .appTransaction, .heldTransaction:
            break
        case .autocommit:
            let mixed = statements.contains { statement in
                !AutocommitOnlyStatement.matches(statement, family: family, grammar: grammar)
                    && writes([statement], databaseType: databaseType)
            }
            return mixed ? .refuseMixed : .runAsIs
        case .scriptTransaction, .sessionTransaction:
            return .runAsIs
        }
        switch sessionState {
        case .idle:
            return .hold
        case .inTransaction, .abortedTransaction:
            return .runAsIs
        case .holdsSessionLocks, .unknown:
            return .refuse
        @unknown default:
            return .refuse
        }
    }

    // A held decision runs held; anything else keeps the plan an automatic connection would use.
    nonisolated internal static func runPlan(
        text plan: BatchTransactionPlan,
        decision: Decision,
        sessionState: PluginSessionTransactionState
    ) -> BatchTransactionPlan {
        decision == .hold ? .heldTransaction : plan.joining(sessionState, commitMode: .automatic)
    }

    // Inside the caller's lease, so nothing runs between the state read and the BEGIN. True when it sent the BEGIN.
    nonisolated internal static func openIfNeeded(
        on driver: DatabaseDriver,
        statements: [String],
        databaseType: DatabaseType,
        grammar: SQLLexicalGrammar,
        commitMode: ConnectionCommitMode
    ) async throws -> Bool {
        guard commitMode == .manual else { return false }
        let state = await driver.heldSessionTransactionState()
        let decided = decision(
            commitMode: commitMode,
            statements: statements,
            databaseType: databaseType,
            grammar: grammar,
            supportsTransactions: driver.supportsTransactions,
            sessionState: state
        )
        if let refusal = decided.refusal { throw refusal }
        guard decided == .hold else { return false }
        let mode = OperationKind.worst(of: statements, databaseType: databaseType).transactionAccessMode
        try await driver.beginTransaction(mode: mode)
        turnHold?.mark(true)
        return true
    }

    // The app's own writes on a Manual Commit session: one the session can't hold is refused before it runs.
    nonisolated internal static func refuseUnheldWrite(
        supportsTransactions: Bool,
        sessionState: PluginSessionTransactionState
    ) throws {
        guard supportsTransactions else { throw ManualCommitRefusal() }
        switch sessionState {
        case .idle, .inTransaction, .abortedTransaction:
            return
        case .holdsSessionLocks, .unknown:
            throw ManualCommitRefusal()
        @unknown default:
            throw ManualCommitRefusal()
        }
    }

    // A timed-out read after the turn's own BEGIN still means the transaction it opened.
    nonisolated internal static func recordedState(
        read: PluginSessionTransactionState,
        turnOpenedHold: Bool
    ) -> PluginSessionTransactionState {
        read == .unknown && turnOpenedHold ? .inTransaction : read
    }

    // A failed first write leaves nothing worth keeping, and on PostgreSQL an aborted block that needs a Roll Back.
    @MainActor
    internal static func rollBackOpened(on driver: DatabaseDriver, connectionId: UUID) async {
        let token = DatabaseManager.shared.beginProtectedWrite(on: driver, for: connectionId)
        defer { DatabaseManager.shared.endProtectedWrite(token, for: connectionId) }
        do {
            try await TaskCancellationShield.run { @Sendable in try await driver.rollbackTransaction() }
            turnHold?.mark(false)
        } catch {
            logger.error("Rolling back the held transaction failed: \(error.publicLogShape, privacy: .public)")
        }
    }

    // A procedure or dynamic batch can end the transaction unseen, and so can a T-SQL batch, which needs no `;` before COMMIT.
    nonisolated internal static func mayEndTransactionUnseen(
        _ statements: [String],
        databaseType: DatabaseType,
        grammar: SQLLexicalGrammar
    ) -> Bool {
        let scansTokens = TransactionEngineFamily.of(databaseType) == .sqlServer
        return statements.contains { statement in
            CatalogChangeClassifier.effect(of: statement, databaseType: databaseType, grammar: grammar).runsUnseenStatements
                || (scansTokens && mentionsTransactionControl(statement, grammar: grammar))
        }
    }

    // END is left out: it closes every T-SQL block and every CASE.
    nonisolated private static func mentionsTransactionControl(_ statement: String, grammar: SQLLexicalGrammar) -> Bool {
        let text = statement as NSString
        var start = 0
        while start < text.length {
            var cursor = SQLTokenCursor(text.substring(from: start) as NSString, grammar: grammar)
            var previous: String?
            while let token = cursor.next() {
                guard let word = token.word else {
                    previous = nil
                    continue
                }
                if controlWords.contains(word) { return true }
                if word == "TRAN" || word == "TRANSACTION", let previous, transactionOpeners.contains(previous) {
                    return true
                }
                previous = word
            }
            start += cursor.location + 1
        }
        return false
    }

    private static let controlWords: Set<String> = ["COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE", "ABORT", "XA"]
    private static let transactionOpeners: Set<String> = ["BEGIN", "SAVE", "START", "DISTRIBUTED"]

    // BEGIN and START are read the way a batch is planned, so a PL/SQL or T-SQL block is not taken for one.
    nonisolated internal static func controlsTransaction(
        _ statements: [String],
        databaseType: DatabaseType,
        grammar: SQLLexicalGrammar
    ) -> Bool {
        if startsTransaction(statements, databaseType: databaseType, grammar: grammar) { return true }
        let isTeradata = TransactionEngineFamily.of(databaseType) == .teradata
        return statements.contains { statement in
            if CatalogChangeClassifier.effect(of: statement, databaseType: databaseType, grammar: grammar).endsTransaction {
                return true
            }
            let keyword = QueryClassifier.leadingKeyword(of: statement, grammar: grammar)
            // Teradata's short form of END TRANSACTION.
            return transactionControlKeywords.contains(keyword) || (isTeradata && keyword == "ET")
        }
    }

    nonisolated internal static func startsTransaction(
        _ statements: [String],
        databaseType: DatabaseType,
        grammar: SQLLexicalGrammar
    ) -> Bool {
        BatchTransactionPolicy.plan(for: statements, databaseType: databaseType, grammar: grammar) == .scriptTransaction
    }

    nonisolated private static func writes(_ statements: [String], databaseType: DatabaseType) -> Bool {
        OperationKind.worst(of: statements, databaseType: databaseType).declaresWrite
    }

    private static let transactionControlKeywords: Set<String> = [
        "COMMIT", "ROLLBACK", "END", "ABORT", "SAVEPOINT", "RELEASE", "XA",
    ]

    internal static var transactionEndedNotice: String {
        String(localized: "The open transaction on this connection ended while this statement ran.")
    }

    internal static var statementOpenedNotice: String {
        String(
            localized: "This change is pending in a transaction the statement opened. Other statements are refused until it is committed or rolled back."
        )
    }

    internal static var pendingNotice: String {
        String(localized: "Manual Commit is on for this connection, so this change is pending until the user commits it in TablePro.")
    }

    internal static var transactionControlRefusalMessage: String {
        String(localized: "Manual Commit is on for this connection. Commit or roll back in TablePro.")
    }

    internal static var openTransactionRefusalMessage: String {
        String(
            localized: "A transaction is already open on this connection, or it cannot say whether one is. Commit or roll it back first."
        )
    }
}
