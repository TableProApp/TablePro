//
//  SessionStateLedger.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

// What the user's own statements set up on each session connection, as kinds only: a value a `SET` carried is kept
// nowhere. A reconnect reads it for the driver it is about to close, since the server cannot be asked once it is gone.
@MainActor
internal final class SessionStateLedger {
    private struct Entry {
        // Weak, and compared by identity: a closed driver that was freed hands its address to the next one allocated.
        weak var driver: AnyObject?
        var state: SQLSessionStateKinds
    }

    private var entries: [SessionTransactionTracker.Key: Entry] = [:]
    private let isLive: @MainActor (SessionTransactionTracker.Key, DatabaseDriver) -> Bool

    internal init(isLive: @escaping @MainActor (SessionTransactionTracker.Key, DatabaseDriver) -> Bool) {
        self.isLive = isLive
    }

    internal func record(_ effect: SQLSessionStateEffect, on driver: DatabaseDriver, for key: SessionTransactionTracker.Key) {
        let current = entries[key].flatMap { $0.driver === driver ? $0.state : nil } ?? []
        // A turn can outlive its session's teardown; its late answer must not land on the replacement.
        guard isLive(key, driver) else {
            if entries[key]?.driver === driver { entries.removeValue(forKey: key) }
            return
        }
        let state = effect.applied(to: current)
        entries[key] = state.isEmpty ? nil : Entry(driver: driver, state: state)
    }

    internal func state(for key: SessionTransactionTracker.Key, heldBy driver: DatabaseDriver) -> SQLSessionStateKinds {
        guard let entry = entries[key], entry.driver === driver else { return [] }
        return entry.state
    }

    internal func state(heldBy driver: DatabaseDriver, for connectionId: UUID) -> SQLSessionStateKinds {
        entries.reduce(into: SQLSessionStateKinds()) { state, item in
            if item.key.connectionId == connectionId, item.value.driver === driver {
                state.formUnion(item.value.state)
            }
        }
    }

    // Drops what a closed, replaced or disconnected driver held, as the transaction tracker drops its holds.
    internal func prune(_ connectionId: UUID) {
        for (key, entry) in entries where key.connectionId == connectionId {
            if let driver = entry.driver as? DatabaseDriver, isLive(key, driver) { continue }
            entries.removeValue(forKey: key)
        }
    }
}

private struct SessionStateReading: Sendable {
    let key: SessionTransactionTracker.Key
    let dialect: SQLSessionDialect
    let grammar: SQLLexicalGrammar
    let startup: [String]
}

extension DatabaseManager {
    // Called inside the user's own lease, where the driver is the one the text ran on. A statement that failed counts:
    // it can have created a temporary table before its error.
    internal func noteSessionStatements(_ statements: [String], ranOn driver: DatabaseDriver, scope: DatabaseScope) async {
        guard !statements.isEmpty,
              let session = activeSessions[scope.connectionId],
              let dialect = SQLSessionDialect(TransactionEngineFamily.of(session.connection.type)),
              let key = sessionKey(for: scope),
              isLiveSessionDriver(driver, for: key)
        else { return }
        let databaseType = session.connection.type
        let grammar = SQLLexicalResolver.readings(for: databaseType, session: driver.sessionLexicalState).execution
        // A reconnect runs the startup commands again, so what they set up is never lost.
        let startup = Self.startupStatements(
            from: session.connection.startupCommands, databaseType: databaseType, grammar: grammar
        )
        let reading = SessionStateReading(key: key, dialect: dialect, grammar: grammar, startup: startup)
        let effect = await Self.sessionStateEffect(of: statements, reading: reading)
        guard !effect.isEmpty else { return }
        sessionStateLedger.record(effect, on: driver, for: key)
    }

    // A Run All of a long script reads every statement, which would hold the main actor.
    @concurrent
    nonisolated private static func sessionStateEffect(
        of statements: [String],
        reading: SessionStateReading
    ) async -> SQLSessionStateEffect {
        SQLSessionStateClassifier.effect(
            ofStatements: statements, dialect: reading.dialect, grammar: reading.grammar, skipping: reading.startup
        )
    }

    // Kinds only, never a statement, a name or a value: a `SET` can carry a secret.
    static func sessionLostMessage(database: String, loss: SessionLoss) -> String {
        guard !loss.state.isEmpty else { return parkedTransactionLostMessage(database: database) }
        let kinds = ListFormatter.localizedString(byJoining: loss.state.localizedNames)
        guard loss.transaction else {
            return String(
                format: String(
                    // swiftlint:disable:next line_length
                    localized: "The connection to %1$@ was lost while it waited and has been reconnected. The new session does not have what the old one set up: %2$@. Set it up again, then run the statements."
                ),
                database, kinds
            )
        }
        return String(
            format: String(
                // swiftlint:disable:next line_length
                localized: "The connection to %1$@ was lost while it waited, and the server rolled back its open transaction. The new session does not have what the old one set up either: %2$@. Set it up again, then run the statements."
            ),
            database, kinds
        )
    }
}

extension SQLSessionDialect {
    // Every engine left out records nothing, as before the ledger existed.
    init?(_ family: TransactionEngineFamily) {
        switch family {
        case .postgres, .redshift, .cockroach:
            self = .postgres
        case .mysql:
            self = .mySQL
        case .sqlServer:
            self = .sqlServer
        case .oracle:
            self = .oracle
        case .sqlite:
            self = .sqlite
        case .duckdb:
            self = .duckDB
        case .redis, .teradata, .other:
            return nil
        }
    }
}

extension SQLSessionStateKinds {
    // In bit order, so a message names the kinds the same way every time.
    var localizedNames: [String] {
        var names: [String] = []
        if contains(.temporaryObjects) { names.append(String(localized: "temporary tables")) }
        if contains(.sessionSettings) { names.append(String(localized: "session settings")) }
        if contains(.userVariables) { names.append(String(localized: "user variables")) }
        if contains(.preparedStatements) { names.append(String(localized: "prepared statements")) }
        if contains(.heldCursors) { names.append(String(localized: "cursors")) }
        if contains(.sessionLocks) { names.append(String(localized: "session locks")) }
        if contains(.listeners) { names.append(String(localized: "LISTEN registrations")) }
        return names
    }
}

extension BatchStatementOutcome {
    // The statement that failed ran too, as `CatalogEvent.statementsRan` counts it. A Stop ran only what it returned.
    func ranCount(of totalCount: Int) -> Int {
        switch self {
        case .completed:
            return totalCount
        case .cancelled(let results):
            return results.count
        case .failed(let results, let failure, _):
            return failure.ranStatementCount(executedCount: results.count, totalCount: totalCount)
        }
    }
}
