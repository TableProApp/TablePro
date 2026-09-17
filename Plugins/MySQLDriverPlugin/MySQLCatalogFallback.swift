//
//  MySQLCatalogFallback.swift
//  MySQLDriverPlugin
//
//  The order a whole-schema read asks its questions in, kept away from the statements so it can be
//  exercised without a server.
//

import Foundation

internal enum MySQLCatalogFallback {
    /// The catalog first, and nothing else on a server that answers it.
    ///
    /// A healthy server costs exactly the statements the catalog read already sent: a non-empty
    /// answer settles the verdict on its own. Only an empty answer pays for `probe`, and only once
    /// per database, because the verdict it reaches is kept.
    ///
    /// A catalog read that throws falls back for this call alone and records nothing, and so does a
    /// probe the server refused. One read failing says less than the two positive signals do, and a
    /// server error is not always the catalog being someone else's: a statement that hit the query
    /// timeout, or a driver reaching the wrong object, would otherwise hold the whole database on
    /// the `SHOW` path for the session and take its table comments and partition counts with it.
    /// The fallback lists the tables first, so a genuinely blind database has its verdict recorded
    /// inside this same call.
    static func read<Value>(
        database: String,
        ledger: MySQLCatalogVisibilityLedger,
        catalog: () async throws -> [String: Value],
        settlesBlindness: (any Error) -> Bool,
        probe: () async throws -> MySQLCatalogProbe,
        show: () async throws -> [String: Value]
    ) async throws -> [String: Value] {
        guard ledger.visibility(of: database) != .blind else {
            return try await degraded(database: database, ledger: ledger, show: show)
        }
        let answer: [String: Value]
        do {
            answer = try await catalog()
        } catch where settlesBlindness(error) {
            return try await degraded(database: database, ledger: ledger, show: show)
        }
        guard answer.isEmpty else {
            ledger.record(.describes, for: database)
            return answer
        }
        switch try await probe() {
        case .settled(.blind), .refused:
            return try await degraded(database: database, ledger: ledger, show: show)
        case .settled(.describes), .unsettled:
            return answer
        }
    }

    /// The table list, which needs no `probe` of its own: the `SHOW` statement it falls back to is
    /// the second signal the probe would have gone looking for.
    ///
    /// A catalog read that throws falls back for this call alone and records nothing, as `read`
    /// does, so `.blind` is reached only from the two positive signals: an empty catalog answer
    /// beside listed tables. That is what a proxy answers. A statement that hit the query timeout is
    /// not, and recording one would hold the whole database on the `SHOW` path for the session and
    /// take its table comments, its partition counts and its generation expressions with it.
    static func list<Row>(
        database: String,
        ledger: MySQLCatalogVisibilityLedger,
        catalog: () async throws -> [Row],
        settlesBlindness: (any Error) -> Bool,
        show: () async throws -> [Row]
    ) async throws -> [Row] {
        guard ledger.visibility(of: database) != .blind else {
            return try await degraded(database: database, ledger: ledger, show: show)
        }
        let catalogRows: [Row]
        do {
            catalogRows = try await catalog()
        } catch where settlesBlindness(error) {
            return try await degraded(database: database, ledger: ledger, show: show)
        }
        guard catalogRows.isEmpty else {
            ledger.record(.describes, for: database)
            return catalogRows
        }
        let listed = try await show()
        if let verdict = MySQLCatalogVisibilityRule.verdict(
            count: .counted(catalogRows.count), listedTables: listed.count
        ) {
            ledger.record(verdict, for: database)
        }
        return listed
    }

    /// At most one extra statement on a healthy server, and two where the catalog is empty because
    /// the database is.
    ///
    /// The count read alone settles a proxy: DBLE answers a scalar aggregate with no row at all,
    /// where a direct server always answers one row. `SHOW FULL TABLES` is asked only when the count
    /// is a genuine zero, which is the one case a count cannot tell apart from a logical database the
    /// proxy holds tables for.
    ///
    /// A count the server refused is not that signal and records nothing: it is one failed read, and
    /// the query timeout refuses exactly like a catalog that cannot speak for the database. Measured
    /// on MySQL 8.4.11 against a database of 2,402 tables with `max_execution_time` at 1ms: this very
    /// count answers `ERROR 3024` on every attempt, and answers 2402 with the cap lifted.
    static func visibility(
        of database: String,
        ledger: MySQLCatalogVisibilityLedger,
        catalogTableCount: () async throws -> MySQLCatalogCount,
        listedTableCount: () async throws -> Int?
    ) async throws -> MySQLCatalogProbe {
        if let known = ledger.visibility(of: database) { return .settled(known) }
        let counted = try await catalogTableCount()
        guard counted != .refused else { return .refused }
        if let settled = MySQLCatalogVisibilityRule.verdict(count: counted, listedTables: nil) {
            ledger.record(settled, for: database)
            return .settled(settled)
        }
        let listed = try await listedTableCount()
        guard let verdict = MySQLCatalogVisibilityRule.verdict(count: counted, listedTables: listed) else {
            return .unsettled
        }
        ledger.record(verdict, for: database)
        return .settled(verdict)
    }

    private static func degraded<Answer>(
        database: String,
        ledger: MySQLCatalogVisibilityLedger,
        show: () async throws -> Answer
    ) async throws -> Answer {
        do {
            return try await show()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            ledger.forget(database)
            throw error
        }
    }
}
