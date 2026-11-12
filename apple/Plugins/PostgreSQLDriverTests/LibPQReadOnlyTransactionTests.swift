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

    private static func context(
        readOnly: Bool,
        origin: PluginStatementOrigin,
        enforcesReadOnly: Bool = false
    ) -> PluginStatementContext {
        var context = PluginStatementContext()
        context.readOnly = readOnly
        context.origin = origin
        context.enforcesReadOnly = enforcesReadOnly
        return context
    }

    private static let externalRead = context(readOnly: true, origin: .external)
    private static let safeModeRead = context(readOnly: false, origin: .app, enforcesReadOnly: true)

    private static let config = DriverConnectionConfig(host: "", port: 0, username: "", password: "", database: "")

    @Test("An external read runs between START TRANSACTION READ ONLY with its pinning SELECT 1 and a ROLLBACK")
    func wrapsTheStatement() throws {
        let wire = Wire()

        let rows = try LibPQReadOnlyTransaction.run(state: .idle, reason: .externalClients, send: wire.send) {
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
            try LibPQReadOnlyTransaction.run(state: state, reason: .externalClients, send: wire.send) {
                try wire.send(Self.statement)
            }
        }

        #expect(wire.sent.isEmpty)
        #expect(error?.message == LibPQReadOnlyTransaction.sessionNotIdle.message)
    }

    @Test(
        "At Read-Only a session that is not idle is refused before anything is sent, and told to roll back",
        arguments: [PluginSessionTransactionState.inTransaction, .abortedTransaction, .holdsSessionLocks, .unknown]
    )
    func safeModeRefusesUnlessIdle(state: PluginSessionTransactionState) {
        let wire = Wire()

        let error = #expect(throws: LibPQPluginError.self) {
            try LibPQReadOnlyTransaction.run(state: state, reason: .safeMode, send: wire.send) {
                try wire.send(Self.statement)
            }
        }

        #expect(wire.sent.isEmpty)
        #expect(error?.message == LibPQReadOnlyTransaction.safeModeSessionNotIdle.message)
        #expect(error?.message != LibPQReadOnlyTransaction.sessionNotIdle.message)
    }

    @Test("A write the read-only transaction refuses comes back as a read-only refusal, and the rollback still goes out",
          arguments: ["25006", "25001"])
    func refusalIsReported(sqlState: String) {
        let wire = Wire()
        let serverMessage = "ERROR:  cannot execute INSERT in a read-only transaction"
        wire.failing[Self.statement] = LibPQPluginError(message: serverMessage, sqlState: sqlState, detail: nil)

        let error = #expect(throws: LibPQPluginError.self) {
            try LibPQReadOnlyTransaction.run(state: .idle, reason: .externalClients, send: wire.send) {
                try wire.send(Self.statement)
            }
        }

        #expect(wire.sent == ["START TRANSACTION READ ONLY; SELECT 1", Self.statement, "ROLLBACK"])
        #expect(error?.sqlState == sqlState)
        #expect(error?.message == LibPQReadOnlyTransaction.refusalMessage(.externalClients))
        #expect(error?.detail == serverMessage)
    }

    @Test("A write refused at Read-Only names Safe Mode and keeps the server's text")
    func safeModeRefusalNamesSafeMode() {
        let wire = Wire()
        let serverMessage = "ERROR:  cannot execute DELETE in a read-only transaction"
        wire.failing[Self.statement] = LibPQPluginError(message: serverMessage, sqlState: "25006", detail: nil)

        let error = #expect(throws: LibPQPluginError.self) {
            try LibPQReadOnlyTransaction.run(state: .idle, reason: .safeMode, send: wire.send) {
                try wire.send(Self.statement)
            }
        }

        #expect(wire.sent == ["START TRANSACTION READ ONLY; SELECT 1", Self.statement, "ROLLBACK"])
        #expect(error?.sqlState == "25006")
        #expect(error?.message == LibPQReadOnlyTransaction.refusalMessage(.safeMode))
        #expect(error?.message != LibPQReadOnlyTransaction.refusalMessage(.externalClients))
        #expect(error?.detail == serverMessage)
    }

    @Test("Any other failure keeps its own message, and the rollback still goes out")
    func otherFailuresPassThrough() {
        let wire = Wire()
        let missing = LibPQPluginError(message: "ERROR:  relation \"orders\" does not exist", sqlState: "42P01", detail: nil)
        wire.failing[Self.statement] = missing

        let error = #expect(throws: LibPQPluginError.self) {
            try LibPQReadOnlyTransaction.run(state: .idle, reason: .safeMode, send: wire.send) {
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
            try LibPQReadOnlyTransaction.run(state: .idle, reason: .externalClients, send: wire.send) {
                try wire.send(Self.statement)
            }
        }

        #expect(!wire.sent.contains(Self.statement))
    }

    @Test("An external read and an app read at Read-Only are wrapped; the app's own read-only marks are not")
    func wrapsOnlyExternalAndSafeModeReads() {
        let capabilities = PostgreSQLPluginDriver(config: Self.config).capabilities

        #expect(LibPQReadOnlyTransaction.reason(for: Self.externalRead, capabilities: capabilities) == .externalClients)
        #expect(LibPQReadOnlyTransaction.reason(for: Self.safeModeRead, capabilities: capabilities) == .safeMode)
        #expect(!LibPQReadOnlyTransaction.applies(to: PluginStatementContext(), capabilities: capabilities))
        #expect(!LibPQReadOnlyTransaction.applies(
            to: Self.context(readOnly: true, origin: .app), capabilities: capabilities
        ))
        #expect(!LibPQReadOnlyTransaction.applies(
            to: Self.context(readOnly: false, origin: .external), capabilities: capabilities
        ))
    }

    // `executeCatalogRead` marks its read `readOnly` from the app with `readsCatalog`; a wrap would drop the pin.
    @Test("An app catalog read keeps its pin, because only Read-Only wraps an app read")
    func catalogReadIsNotWrapped() {
        let capabilities = PostgreSQLPluginDriver(config: Self.config).capabilities
        var catalogRead = Self.context(readOnly: true, origin: .app)
        catalogRead.readsCatalog = true

        #expect(LibPQReadOnlyTransaction.reason(for: catalogRead, capabilities: capabilities) == nil)
    }

    @Test("An external read keeps the external clients' wording when Read-Only is also set")
    func externalReasonWinsForAnExternalRead() {
        let capabilities = PostgreSQLPluginDriver(config: Self.config).capabilities
        let both = Self.context(readOnly: true, origin: .external, enforcesReadOnly: true)
        let writeAtReadOnly = Self.context(readOnly: false, origin: .external, enforcesReadOnly: true)

        #expect(LibPQReadOnlyTransaction.reason(for: both, capabilities: capabilities) == .externalClients)
        #expect(LibPQReadOnlyTransaction.reason(for: writeAtReadOnly, capabilities: capabilities) == .safeMode)
    }

    @Test("PostgreSQL, PGlite and CockroachDB declare read-only statements and honor Read-Only")
    func declaringDrivers() {
        let drivers: [any PluginDatabaseDriver] = [
            PostgreSQLPluginDriver(config: Self.config),
            PGlitePluginDriver(config: Self.config),
            CockroachPluginDriver(config: Self.config),
        ]

        for driver in drivers {
            #expect(driver.capabilities.contains(.readOnlyStatements), "\(type(of: driver))")
            #expect(driver.capabilities.contains(.enforcesReadOnlyMode), "\(type(of: driver))")
            #expect(LibPQReadOnlyTransaction.applies(to: Self.externalRead, capabilities: driver.capabilities))
            #expect(LibPQReadOnlyTransaction.applies(to: Self.safeModeRead, capabilities: driver.capabilities))
        }
    }

    // Redshift documents READ ONLY, but nobody has measured whether it refuses a write there.
    @Test("Redshift runs an external read as it always has, and declares no Read-Only mode")
    func redshiftDoesNotWrap() {
        let redshift = RedshiftPluginDriver(config: Self.config)

        #expect(!redshift.capabilities.contains(.readOnlyStatements))
        #expect(!redshift.capabilities.contains(.enforcesReadOnlyMode))
        #expect(!LibPQReadOnlyTransaction.applies(to: Self.externalRead, capabilities: redshift.capabilities))
        #expect(!LibPQReadOnlyTransaction.applies(to: Self.safeModeRead, capabilities: redshift.capabilities))
    }

    @Test("Redshift hands a bounded read at Read-Only back to the host instead of running it without the mode")
    func redshiftReturnsBoundedReadAtReadOnly() async throws {
        let redshift = RedshiftPluginDriver(config: Self.config)

        let result = try await redshift.executeBoundedQuery(query: Self.statement, rowCap: 10, context: Self.safeModeRead)

        #expect(result == nil)
    }
}
