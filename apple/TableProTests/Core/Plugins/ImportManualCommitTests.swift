//
//  ImportManualCommitTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class ImportHoldDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var current: PluginSessionTransactionState
    private var sent: [String] = []
    private let ddlCommits: Bool

    // `ddlCommits` answers as MySQL does: DDL and LOCK TABLES commit the open transaction.
    init(state: PluginSessionTransactionState = .idle, ddlCommits: Bool = false) {
        current = state
        self.ddlCommits = ddlCommits
    }

    var supportsSchemas: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    var statements: [String] { lock.withLock { sent } }

    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock {
            sent.append(query)
            let upper = query.uppercased()
            switch upper {
            case "BEGIN": current = .inTransaction
            case "COMMIT", "ROLLBACK": current = .idle
            default:
                let head = upper.split(separator: " ").first.map(String.init) ?? ""
                if ddlCommits, ["DROP", "CREATE", "ALTER", "LOCK"].contains(head) { current = .idle }
            }
        }
        return .empty
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { lock.withLock { current } }

    func foreignKeyDisableStatements() -> [String]? { ["PRAGMA foreign_keys = OFF"] }
    func foreignKeyEnableStatements() -> [String]? { ["PRAGMA foreign_keys = ON"] }
}

struct ImportManualCommitTests {
    private func sink(
        on driver: ImportHoldDriver,
        type: DatabaseType = .sqlite,
        commitMode: ConnectionCommitMode = .manual
    ) -> ImportDataSinkAdapter {
        let adapter = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: type), pluginDriver: driver)
        return ImportDataSinkAdapter(driver: adapter, databaseType: type, commitMode: commitMode, importRun: ImportRun())
    }

    @Test("A Manual Commit import holds its transaction: BEGIN, and no COMMIT at the end")
    func importIsHeld() async throws {
        let driver = ImportHoldDriver()
        let sink = sink(on: driver)

        try await sink.prepareImportRun()
        try await sink.beginTransaction()
        try await sink.execute(statement: "INSERT INTO t VALUES (1)", line: 1)
        try await sink.commitTransaction()

        #expect(driver.statements == ["BEGIN", "INSERT INTO t VALUES (1)"])
    }

    @Test(
        "A Manual Commit import the session can't hold is refused before anything runs",
        arguments: [PluginSessionTransactionState.unknown, .holdsSessionLocks]
    )
    func unholdableImportIsRefused(state: PluginSessionTransactionState) async {
        let driver = ImportHoldDriver(state: state)
        let sink = sink(on: driver)

        await #expect(throws: ManualCommitRefusal()) {
            try await sink.prepareImportRun()
        }
        #expect(driver.statements.isEmpty)
    }

    // SQLite ignores the re-enable inside a held transaction, so the checks would stay off for the session.
    @Test("A Manual Commit import that turned foreign key checks off is refused before its first write")
    func foreignKeyToggledImportIsRefused() async throws {
        let driver = ImportHoldDriver()
        let sink = sink(on: driver)

        try await sink.prepareImportRun()
        try await sink.disableForeignKeyChecks()
        await #expect(throws: ManualCommitForeignKeyRefusal()) {
            try await sink.beginTransaction()
        }
        try await sink.enableForeignKeyChecks()

        #expect(driver.statements == ["PRAGMA foreign_keys = OFF", "PRAGMA foreign_keys = ON"])
    }

    // Skip and Continue goes on after a refusal, so every later write is refused as well.
    @Test("A Manual Commit import that never begins a transaction is refused at each write, before it runs")
    func unwrappedImportIsRefused() async throws {
        let driver = ImportHoldDriver()
        let sink = sink(on: driver)

        try await sink.prepareImportRun()
        await #expect(throws: ManualCommitUnwrappedImportRefusal()) {
            try await sink.execute(statement: "INSERT INTO t VALUES (1)", line: 1)
        }
        await #expect(throws: ManualCommitUnwrappedImportRefusal()) {
            try await sink.execute(statement: "INSERT INTO t VALUES (2)", line: 2)
        }

        #expect(driver.statements.isEmpty)
    }

    // A mysqldump drops and creates each table before its rows; after that DDL the rows would autocommit.
    @Test("A held MySQL import refuses the first row after the file's own DDL ended the hold")
    func dumpRowsAfterDDLAreRefused() async throws {
        let driver = ImportHoldDriver(ddlCommits: true)
        let sink = sink(on: driver, type: .mysql)
        try await sink.prepareImportRun()
        try await sink.beginTransaction()

        for (line, statement) in ["DROP TABLE IF EXISTS t", "CREATE TABLE t (id INT)", "LOCK TABLES t WRITE"].enumerated() {
            try await sink.execute(statement: statement, line: line + 1)
        }
        await #expect(throws: ManualCommitMixedRefusal()) {
            try await sink.execute(statement: "INSERT INTO t VALUES (1)", line: 4)
        }

        #expect(driver.statements == ["BEGIN", "DROP TABLE IF EXISTS t", "CREATE TABLE t (id INT)", "LOCK TABLES t WRITE"])
    }

    @Test("A held MySQL import refuses DDL once it has written rows, which stay held")
    func ddlAfterHeldRowsIsRefused() async throws {
        let driver = ImportHoldDriver(ddlCommits: true)
        let sink = sink(on: driver, type: .mysql)
        try await sink.prepareImportRun()
        try await sink.beginTransaction()

        try await sink.execute(statement: "INSERT INTO a VALUES (1)", line: 1)
        await #expect(throws: ManualCommitMixedRefusal()) {
            try await sink.execute(statement: "DROP TABLE IF EXISTS b", line: 2)
        }

        #expect(driver.statements == ["BEGIN", "INSERT INTO a VALUES (1)"])
    }

    @Test("A held import marks the turn's hold at its BEGIN")
    func heldImportMarksTheTurn() async throws {
        let driver = ImportHoldDriver()
        let sink = sink(on: driver)
        let held = ManualCommitTurnHold()

        try await ManualCommit.$turnHold.withValue(held) {
            try await sink.prepareImportRun()
            try await sink.beginTransaction()
        }

        #expect(held.isHeld)
    }

    @Test("An automatic import with foreign key checks off still wraps and commits")
    func automaticImportWithToggleCommits() async throws {
        let driver = ImportHoldDriver()
        let sink = sink(on: driver, commitMode: .automatic)

        try await sink.prepareImportRun()
        try await sink.disableForeignKeyChecks()
        try await sink.beginTransaction()
        try await sink.commitTransaction()

        #expect(driver.statements == ["PRAGMA foreign_keys = OFF", "BEGIN", "COMMIT"])
    }
}
