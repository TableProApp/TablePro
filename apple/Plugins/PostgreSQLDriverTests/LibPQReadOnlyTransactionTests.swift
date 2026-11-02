//
//  LibPQReadOnlyTransactionTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct LibPQReadOnlyTransactionTests {
    private final class Wire {
        var sent: [String] = []
        var failing: [String: LibPQPluginError] = [:]

        func send(_ statement: String) throws {
            sent.append(statement)
            if let error = failing[statement] { throw error }
        }
    }

    private static let statement = "SELECT * FROM orders"

    private static func context(readOnly: Bool, origin: PluginStatementOrigin) -> PluginStatementContext {
        var context = PluginStatementContext()
        context.readOnly = readOnly
        context.origin = origin
        return context
    }

    private static let externalRead = context(readOnly: true, origin: .external)

    private static let config = DriverConnectionConfig(host: "", port: 0, username: "", password: "", database: "")

    @Test("An external read runs between START TRANSACTION READ ONLY with its pinning SELECT 1 and a ROLLBACK")
    func wrapsTheStatement() throws {
        let wire = Wire()

        let rows = try LibPQReadOnlyTransaction.run(state: .idle, send: wire.send) {
            try wire.send(Self.statement)
            return 3
        }

        #expect(rows == 3)
        #expect(wire.sent == ["START TRANSACTION READ ONLY; SELECT 1", Self.statement, "ROLLBACK"])
    }

    // Measured on 17.11: START TRANSACTION READ ONLY inside an open transaction makes the user's transaction read-only.
    @Test(
        "A session that is not idle is refused before anything is sent",
        arguments: [PluginSessionTransactionState.inTransaction, .abortedTransaction, .holdsSessionLocks, .unknown]
    )
    func refusesUnlessIdle(state: PluginSessionTransactionState) {
        let wire = Wire()

        let error = #expect(throws: LibPQPluginError.self) {
            try LibPQReadOnlyTransaction.run(state: state, send: wire.send) {
                try wire.send(Self.statement)
            }
        }

        #expect(wire.sent.isEmpty)
        #expect(error?.message == LibPQReadOnlyTransaction.sessionNotIdle.message)
    }

    @Test("A write the read-only transaction refuses comes back as a read-only refusal, and the rollback still goes out",
          arguments: ["25006", "25001"])
    func refusalIsReported(sqlState: String) {
        let wire = Wire()
        let serverMessage = "ERROR:  cannot execute INSERT in a read-only transaction"
        wire.failing[Self.statement] = LibPQPluginError(message: serverMessage, sqlState: sqlState, detail: nil)

        let error = #expect(throws: LibPQPluginError.self) {
            try LibPQReadOnlyTransaction.run(state: .idle, send: wire.send) {
                try wire.send(Self.statement)
            }
        }

        #expect(wire.sent == ["START TRANSACTION READ ONLY; SELECT 1", Self.statement, "ROLLBACK"])
        #expect(error?.sqlState == sqlState)
        #expect(error?.message != serverMessage)
        #expect(error?.detail == serverMessage)
    }

    @Test("Any other failure keeps its own message, and the rollback still goes out")
    func otherFailuresPassThrough() {
        let wire = Wire()
        let missing = LibPQPluginError(message: "ERROR:  relation \"orders\" does not exist", sqlState: "42P01", detail: nil)
        wire.failing[Self.statement] = missing

        let error = #expect(throws: LibPQPluginError.self) {
            try LibPQReadOnlyTransaction.run(state: .idle, send: wire.send) {
                try wire.send(Self.statement)
            }
        }

        #expect(wire.sent.last == "ROLLBACK")
        #expect(error?.message == missing.message)
    }

    @Test("When the transaction cannot start, the statement is never sent")
    func failedBeginSendsNoStatement() {
        let wire = Wire()
        wire.failing[LibPQReadOnlyTransaction.begin] = LibPQPluginError(message: "refused", sqlState: "0A000", detail: nil)

        #expect(throws: LibPQPluginError.self) {
            try LibPQReadOnlyTransaction.run(state: .idle, send: wire.send) {
                try wire.send(Self.statement)
            }
        }

        #expect(!wire.sent.contains(Self.statement))
    }

    @Test("Only an external read on a driver that declares read-only statements is wrapped")
    func wrapsOnlyExternalReads() {
        let capabilities = PostgreSQLPluginDriver(config: Self.config).capabilities

        #expect(LibPQReadOnlyTransaction.applies(to: Self.externalRead, capabilities: capabilities))
        #expect(!LibPQReadOnlyTransaction.applies(to: PluginStatementContext(), capabilities: capabilities))
        #expect(!LibPQReadOnlyTransaction.applies(
            to: Self.context(readOnly: true, origin: .app), capabilities: capabilities
        ))
        #expect(!LibPQReadOnlyTransaction.applies(
            to: Self.context(readOnly: false, origin: .external), capabilities: capabilities
        ))
    }

    @Test("PostgreSQL, PGlite and CockroachDB declare read-only statements")
    func declaringDrivers() {
        let drivers: [any PluginDatabaseDriver] = [
            PostgreSQLPluginDriver(config: Self.config),
            PGlitePluginDriver(config: Self.config),
            CockroachPluginDriver(config: Self.config),
        ]

        for driver in drivers {
            #expect(driver.capabilities.contains(.readOnlyStatements), "\(type(of: driver))")
            #expect(LibPQReadOnlyTransaction.applies(to: Self.externalRead, capabilities: driver.capabilities))
        }
    }

    // Redshift documents READ ONLY, but nobody has measured whether it refuses a write there.
    @Test("Redshift runs an external read as it always has")
    func redshiftDoesNotWrap() {
        let redshift = RedshiftPluginDriver(config: Self.config)

        #expect(!redshift.capabilities.contains(.readOnlyStatements))
        #expect(!LibPQReadOnlyTransaction.applies(to: Self.externalRead, capabilities: redshift.capabilities))
    }
}
