//
//  MySQLReadOnlyTransactionTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct MySQLReadOnlyTransactionTests {
    private final class Wire {
        var sent: [String] = []
        var failing: [String: MariaDBPluginError] = [:]

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

    private static func driver(variant: String? = nil) -> MySQLPluginDriver {
        MySQLPluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: "",
            additionalFields: variant.map { ["driverVariant": $0] } ?? [:]
        ))
    }

    @Test("An external read runs between a plain START TRANSACTION READ ONLY and a ROLLBACK")
    func wrapsTheStatement() throws {
        let wire = Wire()

        let rows = try MySQLReadOnlyTransaction.run(state: .idle, send: wire.send) {
            try wire.send(Self.statement)
            return 3
        }

        #expect(rows == 3)
        #expect(wire.sent == ["START TRANSACTION READ ONLY", Self.statement, "ROLLBACK"])
    }

    // Measured on 8.4.13 and 11.4.13: START TRANSACTION READ ONLY commits an open transaction and releases LOCK TABLES.
    @Test(
        "A session that is not idle is refused before anything is sent",
        arguments: [PluginSessionTransactionState.inTransaction, .holdsSessionLocks, .abortedTransaction, .unknown]
    )
    func refusesUnlessIdle(state: PluginSessionTransactionState) {
        let wire = Wire()

        let error = #expect(throws: MariaDBPluginError.self) {
            try MySQLReadOnlyTransaction.run(state: state, send: wire.send) {
                try wire.send(Self.statement)
            }
        }

        #expect(wire.sent.isEmpty)
        #expect(error?.message == MySQLReadOnlyTransaction.sessionNotIdle.message)
    }

    @Test("A session holding LOCK TABLES is refused although the server reports no transaction")
    func tableLockIsNotIdle() {
        let wire = Wire()
        var footprint = MySQLSessionFootprint()
        footprint.observe("LOCK TABLES orders WRITE", lexicalFeatures: MySQLLexicalFeatures.mySQL)

        #expect(throws: MariaDBPluginError.self) {
            try MySQLReadOnlyTransaction.run(
                state: footprint.transactionState(isInTransaction: false),
                send: wire.send
            ) {
                try wire.send(Self.statement)
            }
        }

        #expect(wire.sent.isEmpty)
    }

    @Test("Error 1792 comes back as a read-only refusal, and the rollback still goes out")
    func refusalIsReported() {
        let wire = Wire()
        let serverMessage = "Cannot execute statement in a READ ONLY transaction."
        wire.failing[Self.statement] = MariaDBPluginError(code: 1_792, message: serverMessage, sqlState: "25006")

        let error = #expect(throws: MariaDBPluginError.self) {
            try MySQLReadOnlyTransaction.run(state: .idle, send: wire.send) {
                try wire.send(Self.statement)
            }
        }

        #expect(wire.sent == ["START TRANSACTION READ ONLY", Self.statement, "ROLLBACK"])
        #expect(error?.code == 1_792)
        #expect(error?.sqlState == "25006")
        #expect(error?.message != serverMessage)
    }

    @Test("Any other failure keeps its own message, and the rollback still goes out")
    func otherFailuresPassThrough() {
        let wire = Wire()
        let missing = MariaDBPluginError(code: 1_146, message: "Table 'shop.orders' doesn't exist", sqlState: "42S02")
        wire.failing[Self.statement] = missing

        let error = #expect(throws: MariaDBPluginError.self) {
            try MySQLReadOnlyTransaction.run(state: .idle, send: wire.send) {
                try wire.send(Self.statement)
            }
        }

        #expect(wire.sent.last == "ROLLBACK")
        #expect(error?.code == 1_146)
        #expect(error?.message == missing.message)
    }

    @Test("A server too old for READ ONLY refuses the begin, and the statement is never sent")
    func oldServerSendsNoStatement() {
        let wire = Wire()
        wire.failing[MySQLReadOnlyTransaction.begin] = MariaDBPluginError(
            code: 1_064, message: "You have an error in your SQL syntax", sqlState: "42000"
        )

        let error = #expect(throws: MariaDBPluginError.self) {
            try MySQLReadOnlyTransaction.run(state: .idle, send: wire.send) {
                try wire.send(Self.statement)
            }
        }

        #expect(!wire.sent.contains(Self.statement))
        #expect(error?.code == 1_064)
    }

    @Test("Only an external read on MySQL or MariaDB is wrapped", arguments: [
        (MySQLServerFlavor.mysql, true),
        (.mariadb, true),
        (.tidb(version: MySQLEngineVersion(major: 8, minor: 5, patch: 1)), false),
        (.oceanbase(version: nil), false),
        (.databend, false),
        (.starrocks, false),
    ])
    func wrapsOnlyEnforcingFlavors(flavor: MySQLServerFlavor, wraps: Bool) {
        #expect(MySQLReadOnlyTransaction.applies(to: Self.externalRead, flavor: flavor) == wraps)
        #expect(!MySQLReadOnlyTransaction.applies(to: PluginStatementContext(), flavor: flavor))
        #expect(!MySQLReadOnlyTransaction.applies(to: Self.context(readOnly: true, origin: .app), flavor: flavor))
    }

    @Test("The driver declares read-only statements only for a flavor that enforces them")
    func capabilityFollowsFlavor() {
        #expect(Self.driver().capabilities.contains(.readOnlyStatements))
        for variant in [
            MySQLServerFlavor.oceanbaseVariant, MySQLServerFlavor.databendVariant, MySQLServerFlavor.starrocksVariant,
        ] {
            #expect(!Self.driver(variant: variant).capabilities.contains(.readOnlyStatements), "\(variant)")
        }
    }
}
