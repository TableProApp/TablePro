//
//  DuckDBTransactionProbeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("DuckDB transaction probe")
struct DuckDBTransactionProbeTests {
    /// Measured against the shipped libduckdb v1.5.2: outside a transaction two calls answered 6
    /// then 10, and inside one they both answered 12.
    @Test("The same transaction id twice is one open transaction, two different ones is none")
    func repeatedIdMeansAnOpenTransaction() {
        #expect(DuckDBTransactionProbe.state(first: .value("12"), second: .value("12")) == .inTransaction)
        #expect(DuckDBTransactionProbe.state(first: .value("6"), second: .value("10")) == .idle)
    }

    @Test("A refusal because the transaction is aborted is the answer, not a failure")
    func abortedTransactionIsReported() {
        #expect(DuckDBTransactionProbe.state(first: .abortedTransaction, second: .value("1")) == .abortedTransaction)
        #expect(DuckDBTransactionProbe.state(first: .value("1"), second: .abortedTransaction) == .abortedTransaction)
    }

    @Test("A reading that could not be taken says so rather than guessing")
    func unreadableIsUnknown() {
        #expect(DuckDBTransactionProbe.state(first: .unreadable, second: .value("1")) == .unknown)
        #expect(DuckDBTransactionProbe.state(first: .value("1"), second: .unreadable) == .unknown)
        #expect(DuckDBTransactionProbe.state(first: .unreadable, second: .unreadable) == .unknown)
    }

    @Test("A DuckDB catalog settles nothing on its own: the transaction id has to be probed")
    func nativeCatalogNeedsTheProbe() {
        #expect(DuckDBTransactionProbe.state(catalogType: .value("duckdb"), tracksOpenTransaction: false) == nil)
        #expect(DuckDBTransactionProbe.state(catalogType: .value("DuckDB"), tracksOpenTransaction: true) == nil)
    }

    /// The probe is destructive outside DuckDB's own transaction manager. Measured against v1.5.2
    /// with a SQLite catalog in front: `txid_current()` failed with `DuckTransaction::Get called on
    /// non-DuckDB transaction` and aborted the user's transaction, losing the row they had inserted.
    @Test("A catalog DuckDB does not own is answered from the statements the driver saw")
    func foreignCatalogUsesTheTrackedAnswer() {
        #expect(DuckDBTransactionProbe.state(catalogType: .value("sqlite"), tracksOpenTransaction: true) == .inTransaction)
        #expect(DuckDBTransactionProbe.state(catalogType: .value("sqlite"), tracksOpenTransaction: false) == .idle)
        #expect(DuckDBTransactionProbe.state(catalogType: .value("postgres"), tracksOpenTransaction: true) == .inTransaction)
    }

    @Test("A catalog read that was refused for being in an aborted transaction says so")
    func abortedCatalogReadIsReported() {
        let state = DuckDBTransactionProbe.state(catalogType: .abortedTransaction, tracksOpenTransaction: false)
        #expect(state == .abortedTransaction)
    }

    @Test("A catalog nobody could read leaves the caller deciding as if it had not asked")
    func unreadableCatalogIsUnknown() {
        #expect(DuckDBTransactionProbe.state(catalogType: .unreadable, tracksOpenTransaction: true) == .unknown)
    }

    @Test("The probe asks for text, because the deprecated value API faults on other types")
    func probeQueriesCastToText() {
        #expect(DuckDBTransactionProbe.transactionIdQuery == "SELECT txid_current()::VARCHAR")
        #expect(DuckDBTransactionProbe.catalogTypeQuery.contains("duckdb_databases()"))
        #expect(DuckDBTransactionProbe.catalogTypeQuery.contains("current_database()"))
    }
}
