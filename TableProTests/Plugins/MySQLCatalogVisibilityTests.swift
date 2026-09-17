//
//  MySQLCatalogVisibilityTests.swift
//  TableProTests
//
//  Whether `information_schema` describes the database a read was asked about, and what a
//  whole-schema read does about it.
//
//  The statements are behind closures here, so the order they are sent in and the verdict that is
//  kept are both counted without a server.
//

import Foundation
import Testing

@Suite("MySQL catalog visibility rule")
struct MySQLCatalogVisibilityRuleTests {
    @Test("A catalog with rows describes the database, whatever SHOW says")
    func rowsSettleIt() {
        #expect(MySQLCatalogVisibilityRule.verdict(count: .counted(5), listedTables: 5) == .describes)
        #expect(MySQLCatalogVisibilityRule.verdict(count: .counted(5), listedTables: 0) == .describes)
        #expect(MySQLCatalogVisibilityRule.verdict(count: .counted(5), listedTables: nil) == .describes)
    }

    /// DBLE 3.23 and ShardingSphere-Proxy 5.5.3 answer a logical database's catalog with nothing
    /// while `SHOW FULL TABLES` lists its tables.
    @Test("An empty catalog beside listed tables is blind")
    func emptyCatalogWithTablesIsBlind() {
        #expect(MySQLCatalogVisibilityRule.verdict(count: .counted(0), listedTables: 5) == .blind)
    }

    /// A scalar aggregate with no row at all is DBLE 3.23's answer, and a direct server never gives
    /// it: every MySQL and MariaDB answers one row, zero included.
    @Test("A count that answered no row is blind on its own")
    func noRowIsBlind() {
        #expect(MySQLCatalogVisibilityRule.verdict(count: .noRow, listedTables: nil) == .blind)
        #expect(MySQLCatalogVisibilityRule.verdict(count: .noRow, listedTables: 0) == .blind)
    }

    /// A refusal is one failed read, not the catalog disowning the database. Measured on MySQL
    /// 8.4.11 against a database of 2,402 tables with `max_execution_time` at 1ms: the count answers
    /// `ERROR 3024` on every attempt, and 2402 with the cap lifted.
    @Test("A refused read reaches no verdict at all")
    func refusedReadSettlesNothing() {
        #expect(MySQLCatalogVisibilityRule.verdict(count: .refused, listedTables: nil) == nil)
        #expect(MySQLCatalogVisibilityRule.verdict(count: .refused, listedTables: 0) == nil)
        #expect(MySQLCatalogVisibilityRule.verdict(count: .refused, listedTables: 5) == nil)
    }

    /// Two answers settle nothing and must stay uncached: a database with no tables reads as zero
    /// from both, and an account that may list a database but not open it gets an empty catalog
    /// answer and `ERROR 1044` from `SHOW FULL TABLES`, measured in #2950.
    @Test("Neither an empty database nor a refused SHOW reaches a verdict")
    func ambiguousAnswersStayUnresolved() {
        #expect(MySQLCatalogVisibilityRule.verdict(count: .counted(0), listedTables: 0) == nil)
        #expect(MySQLCatalogVisibilityRule.verdict(count: .counted(0), listedTables: nil) == nil)
    }

    @Test("A server error settles blindness and a client error does not")
    func serverErrorsSettleBlindness() {
        for code: UInt32 in [1_044, 1_064, 1_146] {
            #expect(MySQLCatalogVisibilityRule.settlesBlindness(code: code), "code \(code)")
        }
        for code: UInt32 in [0, 2_000, 2_013, 2_999] {
            #expect(!MySQLCatalogVisibilityRule.settlesBlindness(code: code), "code \(code)")
        }
    }
}

private struct ScriptedFailure: Error {
    let settles: Bool
}

private func settlesBlindness(_ error: any Error) -> Bool {
    (error as? ScriptedFailure)?.settles ?? false
}

@Suite("MySQL catalog fallback")
struct MySQLCatalogFallbackTests {
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var sent: [String] = []

        func send(_ statement: String) {
            lock.withLock { sent.append(statement) }
        }
    }

    /// The whole point of learning the verdict: a server that answers the catalog is asked nothing
    /// else, ever.
    @Test("A catalog that answers costs no extra statement and is never probed")
    func healthyCatalogIsNeverProbed() async throws {
        let script = Script()
        let ledger = MySQLCatalogVisibilityLedger()

        let answer = try await MySQLCatalogFallback.read(
            database: "db1",
            ledger: ledger,
            catalog: { script.send("catalog"); return ["orders": 1] },
            settlesBlindness: settlesBlindness,
            probe: { script.send("probe"); return .unsettled },
            show: { script.send("show"); return [:] }
        )

        #expect(answer == ["orders": 1])
        #expect(script.sent == ["catalog"])
        #expect(ledger.visibility(of: "db1") == .describes)
    }

    /// One failed read says less than the two positive signals do: the fallback lists the tables
    /// first, and a genuinely blind database has its verdict recorded there. A server error that
    /// was the query timeout, or a driver reaching the wrong object, would otherwise hold the whole
    /// database on the `SHOW` path for the session.
    @Test("A refused catalog read falls back for that call and records no verdict")
    func refusedCatalogFallsBack() async throws {
        let script = Script()
        let ledger = MySQLCatalogVisibilityLedger()

        let answer = try await MySQLCatalogFallback.read(
            database: "db1",
            ledger: ledger,
            catalog: { script.send("catalog"); throw ScriptedFailure(settles: true) },
            settlesBlindness: settlesBlindness,
            probe: { script.send("probe"); return .unsettled },
            show: { script.send("show"); return ["orders": 2] }
        )

        #expect(answer == ["orders": 2])
        #expect(script.sent == ["catalog", "show"])
        #expect(ledger.visibility(of: "db1") == nil)
    }

    /// A connection that failed would fail the fallback too, so the error is the caller's.
    @Test("A client failure propagates untouched and records nothing")
    func clientFailurePropagates() async {
        let script = Script()
        let ledger = MySQLCatalogVisibilityLedger()

        await #expect(throws: ScriptedFailure.self) {
            _ = try await MySQLCatalogFallback.read(
                database: "db1",
                ledger: ledger,
                catalog: { throw ScriptedFailure(settles: false) },
                settlesBlindness: settlesBlindness,
                probe: { script.send("probe"); return .unsettled },
                show: { script.send("show"); return [String: Int]() }
            )
        }

        #expect(script.sent.isEmpty)
        #expect(ledger.visibility(of: "db1") == nil)
    }

    @Test("An empty catalog answer stands where the probe finds the catalog sound")
    func emptyCatalogOnAHealthyServer() async throws {
        let script = Script()
        let ledger = MySQLCatalogVisibilityLedger()

        let answer = try await MySQLCatalogFallback.read(
            database: "db1",
            ledger: ledger,
            catalog: { script.send("catalog"); return [String: Int]() },
            settlesBlindness: settlesBlindness,
            probe: { script.send("probe"); return .settled(.describes) },
            show: { script.send("show"); return ["orders": 3] }
        )

        #expect(answer.isEmpty)
        #expect(script.sent == ["catalog", "probe"])
    }

    /// The #2950 account, which may list a database but not open it: the count answers zero and
    /// `SHOW FULL TABLES` answers `ERROR 1044`, so neither read settles anything. The catalog's own
    /// empty answer stands, rather than degrading into one failing `SHOW` per table.
    @Test("An unsettled probe leaves the empty catalog answer standing")
    func unsettledProbeKeepsTheEmptyAnswer() async throws {
        let script = Script()
        let ledger = MySQLCatalogVisibilityLedger()

        let answer = try await MySQLCatalogFallback.read(
            database: "db1",
            ledger: ledger,
            catalog: { script.send("catalog"); return [String: Int]() },
            settlesBlindness: settlesBlindness,
            probe: { script.send("probe"); return .unsettled },
            show: { script.send("show"); return ["orders": 3] }
        )

        #expect(answer.isEmpty)
        #expect(script.sent == ["catalog", "probe"])
        #expect(ledger.visibility(of: "db1") == nil)
    }

    /// A probe the server refused is one failed read, which the query timeout produces on a sound
    /// catalog. The `SHOW` path stands in for this call and nothing is kept, so the next read asks
    /// the catalog again instead of paying per table for the rest of the session.
    @Test("A refused probe falls back for that call and records no verdict")
    func refusedProbeFallsBack() async throws {
        let script = Script()
        let ledger = MySQLCatalogVisibilityLedger()

        let answer = try await MySQLCatalogFallback.read(
            database: "db1",
            ledger: ledger,
            catalog: { script.send("catalog"); return [String: Int]() },
            settlesBlindness: settlesBlindness,
            probe: { script.send("probe"); return .refused },
            show: { script.send("show"); return ["orders": 3] }
        )

        #expect(answer == ["orders": 3])
        #expect(script.sent == ["catalog", "probe", "show"])
        #expect(ledger.visibility(of: "db1") == nil)
    }

    /// A blind verdict already reached skips the catalog read entirely, so a proxied schema costs
    /// the `SHOW` statements and nothing else.
    @Test("A database already known blind sends no catalog read")
    func knownBlindSkipsTheCatalog() async throws {
        let script = Script()
        let ledger = MySQLCatalogVisibilityLedger()
        ledger.record(.blind, for: "db1")

        _ = try await MySQLCatalogFallback.read(
            database: "db1",
            ledger: ledger,
            catalog: { script.send("catalog"); return [String: Int]() },
            settlesBlindness: settlesBlindness,
            probe: { script.send("probe"); return .unsettled },
            show: { script.send("show"); return ["orders": 4] }
        )

        #expect(script.sent == ["show"])
    }

    /// Leaving a verdict in place after the fallback it chose failed too would hold the database on
    /// the `SHOW` path for the session's life.
    @Test("A failed fallback withdraws the verdict it was reached under")
    func failedFallbackWithdrawsTheMark() async {
        let ledger = MySQLCatalogVisibilityLedger()
        ledger.record(.blind, for: "db1")

        await #expect(throws: ScriptedFailure.self) {
            _ = try await MySQLCatalogFallback.read(
                database: "db1",
                ledger: ledger,
                catalog: { [String: Int]() },
                settlesBlindness: settlesBlindness,
                probe: { .unsettled },
                show: { () -> [String: Int] in throw ScriptedFailure(settles: false) }
            )
        }

        #expect(ledger.visibility(of: "db1") == nil)
    }

    // MARK: - The table list

    /// The list settles its own verdict, so the two positive signals are the only way to reach
    /// `.blind`: a catalog that answered nothing where `SHOW FULL TABLES` names tables.
    @Test("An empty catalog answer beside listed tables records blind")
    func emptyListWithListedTablesIsBlind() async throws {
        let script = Script()
        let ledger = MySQLCatalogVisibilityLedger()

        let rows = try await MySQLCatalogFallback.list(
            database: "db1",
            ledger: ledger,
            catalog: { script.send("catalog"); return [String]() },
            settlesBlindness: settlesBlindness,
            show: { script.send("show"); return ["orders", "items"] }
        )

        #expect(rows == ["orders", "items"])
        #expect(script.sent == ["catalog", "show"])
        #expect(ledger.visibility(of: "db1") == .blind)
    }

    /// The query timeout is a server error like any other, so recording blindness from one failed
    /// read would hold the database on the `SHOW` path for the session and take its table comments,
    /// its partition counts and every generated column's expression with it.
    @Test("A refused catalog list falls back for that call and leaves the ledger untouched")
    func refusedListRecordsNothing() async throws {
        let script = Script()
        let ledger = MySQLCatalogVisibilityLedger()

        let rows = try await MySQLCatalogFallback.list(
            database: "db1",
            ledger: ledger,
            catalog: { script.send("catalog"); throw ScriptedFailure(settles: true) },
            settlesBlindness: settlesBlindness,
            show: { script.send("show"); return ["orders"] }
        )

        #expect(rows == ["orders"])
        #expect(script.sent == ["catalog", "show"])
        #expect(ledger.visibility(of: "db1") == nil)
    }

    @Test("A catalog that lists tables is the answer and records describes")
    func catalogListSettlesItself() async throws {
        let script = Script()
        let ledger = MySQLCatalogVisibilityLedger()

        let rows = try await MySQLCatalogFallback.list(
            database: "db1",
            ledger: ledger,
            catalog: { script.send("catalog"); return ["orders"] },
            settlesBlindness: settlesBlindness,
            show: { script.send("show"); return ["items"] }
        )

        #expect(rows == ["orders"])
        #expect(script.sent == ["catalog"])
        #expect(ledger.visibility(of: "db1") == .describes)
    }

    @Test("A database with no tables records nothing either way")
    func emptyDatabaseListStaysUnresolved() async throws {
        let ledger = MySQLCatalogVisibilityLedger()

        let rows = try await MySQLCatalogFallback.list(
            database: "db1",
            ledger: ledger,
            catalog: { [String]() },
            settlesBlindness: settlesBlindness,
            show: { [String]() }
        )

        #expect(rows.isEmpty)
        #expect(ledger.visibility(of: "db1") == nil)
    }

    @Test("A database already known blind lists without a catalog read")
    func knownBlindListSkipsTheCatalog() async throws {
        let script = Script()
        let ledger = MySQLCatalogVisibilityLedger()
        ledger.record(.blind, for: "db1")

        _ = try await MySQLCatalogFallback.list(
            database: "db1",
            ledger: ledger,
            catalog: { script.send("catalog"); return [String]() },
            settlesBlindness: settlesBlindness,
            show: { script.send("show"); return ["orders"] }
        )

        #expect(script.sent == ["show"])
        #expect(ledger.visibility(of: "db1") == .blind)
    }

    // MARK: - The probe

    @Test("A count with rows settles the verdict without asking SHOW")
    func countWithRowsSettlesIt() async throws {
        let script = Script()
        let ledger = MySQLCatalogVisibilityLedger()

        let probe = try await MySQLCatalogFallback.visibility(
            of: "db1",
            ledger: ledger,
            catalogTableCount: { script.send("count"); return .counted(7) },
            listedTableCount: { script.send("show"); return 7 }
        )

        #expect(probe == .settled(.describes))
        #expect(script.sent == ["count"])
        #expect(ledger.visibility(of: "db1") == .describes)
    }

    /// DBLE 3.23 answers a scalar aggregate with no row at all, where a direct server always
    /// answers one.
    @Test("A count that answers no row is blind without asking SHOW")
    func countWithNoRowIsBlind() async throws {
        let script = Script()
        let ledger = MySQLCatalogVisibilityLedger()

        let probe = try await MySQLCatalogFallback.visibility(
            of: "db1",
            ledger: ledger,
            catalogTableCount: { script.send("count"); return .noRow },
            listedTableCount: { script.send("show"); return 7 }
        )

        #expect(probe == .settled(.blind))
        #expect(script.sent == ["count"])
        #expect(ledger.visibility(of: "db1") == .blind)
    }

    /// A refused count is one failed read on a server that may be answering everything else. Keeping
    /// it uncached is what stops a single query timeout pinning the database to the `SHOW` path for
    /// the session and taking its comments, partition counts and generation expressions with it.
    @Test("A refused count records nothing across consecutive reads")
    func refusedCountLeavesTheCacheUntouched() async throws {
        let script = Script()
        let ledger = MySQLCatalogVisibilityLedger()

        for _ in 0 ..< 2 {
            let probe = try await MySQLCatalogFallback.visibility(
                of: "db1",
                ledger: ledger,
                catalogTableCount: { script.send("count"); return .refused },
                listedTableCount: { script.send("show"); return 7 }
            )
            #expect(probe == .refused)
            #expect(ledger.visibility(of: "db1") == nil)
        }

        #expect(script.sent == ["count", "count"])
    }

    @Test("A genuine zero asks SHOW, and tables there make it blind")
    func zeroCountWithListedTables() async throws {
        let script = Script()
        let ledger = MySQLCatalogVisibilityLedger()

        let probe = try await MySQLCatalogFallback.visibility(
            of: "db1",
            ledger: ledger,
            catalogTableCount: { script.send("count"); return .counted(0) },
            listedTableCount: { script.send("show"); return 5 }
        )

        #expect(probe == .settled(.blind))
        #expect(script.sent == ["count", "show"])
    }

    /// An account that may list a database but not open it answers 0 from the catalog and
    /// `ERROR 1044` from `SHOW FULL TABLES`. Measured on MySQL 8.4.11 with an account holding only
    /// the global `SHOW DATABASES` privilege: the count answers one row of `0`, which is a counted
    /// zero and not a missing row, and the `SHOW` is refused. Recording that as blind would turn
    /// every later whole-schema read there into one failing `SHOW` per table.
    @Test("A refused SHOW leaves the verdict unrecorded across consecutive reads")
    func refusedShowLeavesTheCacheUntouched() async throws {
        let script = Script()
        let ledger = MySQLCatalogVisibilityLedger()

        for _ in 0 ..< 2 {
            let probe = try await MySQLCatalogFallback.visibility(
                of: "db1",
                ledger: ledger,
                catalogTableCount: { script.send("count"); return .counted(0) },
                listedTableCount: { script.send("show"); return nil }
            )
            #expect(probe == .unsettled)
            #expect(ledger.visibility(of: "db1") == nil)
        }

        #expect(script.sent == ["count", "show", "count", "show"])
    }

    @Test("A database with no tables settles nothing either")
    func emptyDatabaseStaysUnresolved() async throws {
        let ledger = MySQLCatalogVisibilityLedger()

        let probe = try await MySQLCatalogFallback.visibility(
            of: "db1",
            ledger: ledger,
            catalogTableCount: { .counted(0) },
            listedTableCount: { 0 }
        )

        #expect(probe == .unsettled)
        #expect(ledger.visibility(of: "db1") == nil)
    }

    @Test("A verdict already recorded is answered from the ledger with no statement")
    func recordedVerdictCostsNothing() async throws {
        let script = Script()
        let ledger = MySQLCatalogVisibilityLedger()
        ledger.record(.blind, for: "db1")

        let probe = try await MySQLCatalogFallback.visibility(
            of: "db1",
            ledger: ledger,
            catalogTableCount: { script.send("count"); return .counted(7) },
            listedTableCount: { script.send("show"); return 7 }
        )

        #expect(probe == .settled(.blind))
        #expect(script.sent.isEmpty)
    }

    @Test("A verdict is one database's, not the connection's")
    func verdictsAreKeyedByDatabase() {
        let ledger = MySQLCatalogVisibilityLedger()
        ledger.record(.blind, for: "logical_orders")
        ledger.record(.describes, for: "db1")

        #expect(ledger.visibility(of: "logical_orders") == .blind)
        #expect(ledger.visibility(of: "db1") == .describes)

        ledger.clear()
        #expect(ledger.visibility(of: "db1") == nil)
    }
}
