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

    private static func driver(variant: String? = nil) -> MySQLPluginDriver {
        MySQLPluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: "",
            additionalFields: variant.map { ["driverVariant": $0] } ?? [:]
        ))
    }

    private static let nonEnforcingVariants = [
        MySQLServerFlavor.oceanbaseVariant, MySQLServerFlavor.databendVariant, MySQLServerFlavor.starrocksVariant,
    ]

    @Test("An external read runs between a plain START TRANSACTION READ ONLY and a ROLLBACK")
    func wrapsTheStatement() throws {
        let wire = Wire()

        let rows = try MySQLReadOnlyTransaction.run(state: .idle, reason: .externalClients, send: wire.send) {
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
            try MySQLReadOnlyTransaction.run(state: state, reason: .externalClients, send: wire.send) {
                try wire.send(Self.statement)
            }
        }

        #expect(wire.sent.isEmpty)
        #expect(error?.message == MySQLReadOnlyTransaction.sessionNotIdle.message)
    }

    @Test(
        "At Read-Only a session that is not idle is refused before anything is sent, naming Safe Mode",
        arguments: [PluginSessionTransactionState.inTransaction, .holdsSessionLocks, .abortedTransaction, .unknown]
    )
    func safeModeRefusesUnlessIdle(state: PluginSessionTransactionState) {
        let wire = Wire()

        let error = #expect(throws: MariaDBPluginError.self) {
            try MySQLReadOnlyTransaction.run(state: state, reason: .safeMode, send: wire.send) {
                try wire.send(Self.statement)
            }
        }

        #expect(wire.sent.isEmpty)
        #expect(error?.message == MySQLReadOnlyTransaction.safeModeSessionNotIdle.message)
        #expect(error?.message != MySQLReadOnlyTransaction.sessionNotIdle.message)
    }

    @Test("A session holding LOCK TABLES is refused although the server reports no transaction")
    func tableLockIsNotIdle() {
        let wire = Wire()
        var footprint = MySQLSessionFootprint()
        footprint.observe("LOCK TABLES orders WRITE", lexicalFeatures: MySQLLexicalFeatures.mySQL)

        #expect(throws: MariaDBPluginError.self) {
            try MySQLReadOnlyTransaction.run(
                state: footprint.transactionState(isInTransaction: false),
                reason: .externalClients,
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
            try MySQLReadOnlyTransaction.run(state: .idle, reason: .externalClients, send: wire.send) {
                try wire.send(Self.statement)
            }
        }

        #expect(wire.sent == ["START TRANSACTION READ ONLY", Self.statement, "ROLLBACK"])
        #expect(error?.code == 1_792)
        #expect(error?.sqlState == "25006")
        #expect(error?.message == MySQLReadOnlyTransaction.refusalMessage(.externalClients))
    }

    // A stored function that writes fails inside the read-only transaction with 1792, which is the EX-1 case.
    @Test("At Read-Only error 1792 names Safe Mode, and the rollback still goes out")
    func safeModeRefusalNamesSafeMode() {
        let wire = Wire()
        let call = "SELECT purge_orders()"
        wire.failing[call] = MariaDBPluginError(
            code: 1_792, message: "Cannot execute statement in a READ ONLY transaction.", sqlState: "25006"
        )

        let error = #expect(throws: MariaDBPluginError.self) {
            try MySQLReadOnlyTransaction.run(state: .idle, reason: .safeMode, send: wire.send) {
                try wire.send(call)
            }
        }

        #expect(wire.sent == ["START TRANSACTION READ ONLY", call, "ROLLBACK"])
        #expect(error?.code == 1_792)
        #expect(error?.message == MySQLReadOnlyTransaction.refusalMessage(.safeMode))
        #expect(error?.message != MySQLReadOnlyTransaction.refusalMessage(.externalClients))
    }

    @Test("Any other failure keeps its own message, and the rollback still goes out")
    func otherFailuresPassThrough() {
        let wire = Wire()
        let missing = MariaDBPluginError(code: 1_146, message: "Table 'shop.orders' doesn't exist", sqlState: "42S02")
        wire.failing[Self.statement] = missing

        let error = #expect(throws: MariaDBPluginError.self) {
            try MySQLReadOnlyTransaction.run(state: .idle, reason: .externalClients, send: wire.send) {
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
            try MySQLReadOnlyTransaction.run(state: .idle, reason: .externalClients, send: wire.send) {
                try wire.send(Self.statement)
            }
        }

        #expect(!wire.sent.contains(Self.statement))
        #expect(error?.code == 1_064)
    }

    // A `SET autocommit = 0` session always holds a transaction, so Read-Only could otherwise run nothing there.
    @Test(
        "At Read-Only a session that is not idle runs a statement with no unlisted call as it is",
        arguments: [PluginSessionTransactionState.inTransaction, .holdsSessionLocks, .abortedTransaction, .unknown]
    )
    func runsInTheOpenTransaction(state: PluginSessionTransactionState) throws {
        let wire = Wire()

        let rows = try MySQLReadOnlyTransaction.run(
            state: state, reason: .safeMode, runsInOpenTransaction: true, send: wire.send
        ) {
            try wire.send(Self.statement)
            return 3
        }

        #expect(rows == 3)
        #expect(wire.sent == [Self.statement])
    }

    @Test("An idle session still takes the read-only transaction for a statement with no unlisted call")
    func idleSessionStillWraps() throws {
        let wire = Wire()

        try MySQLReadOnlyTransaction.run(state: .idle, reason: .safeMode, runsInOpenTransaction: true, send: wire.send) {
            try wire.send(Self.statement)
        }

        #expect(wire.sent == ["START TRANSACTION READ ONLY", Self.statement, "ROLLBACK"])
    }

    // Measured on MySQL 5.5.62 and MariaDB 5.5.64: `START TRANSACTION READ ONLY` is error 1064 there. Read-Only falls
    // to Safe Mode's function check; an external read keeps failing at the begin, as nothing else checks it.
    @Test("A server before the READ ONLY characteristic runs a Read-Only read as it is", arguments: [
        ("5.5.62", MySQLServerFlavor.mysql, false),
        ("5.6.4-m7", .mysql, false),
        ("5.6.5", .mysql, true),
        ("8.4.13", .mysql, true),
        ("5.5.64-MariaDB-1~trusty", .mariadb, false),
        ("10.0.38-MariaDB", .mariadb, true),
        ("11.4.13-MariaDB-ubu2404", .mariadb, true),
    ])
    func olderServerIsNotWrapped(banner: String, flavor: MySQLServerFlavor, wraps: Bool) {
        #expect(MySQLReadOnlyTransaction.isAvailable(banner: banner, flavor: flavor) == wraps)
        #expect((MySQLReadOnlyTransaction.reason(for: Self.safeModeRead, flavor: flavor, banner: banner) != nil) == wraps)
        #expect(MySQLReadOnlyTransaction.reason(for: Self.externalRead, flavor: flavor, banner: banner) == .externalClients)
    }

    @Test("Only an external read or a Read-Only statement on MySQL or MariaDB is wrapped", arguments: [
        (MySQLServerFlavor.mysql, true),
        (.mariadb, true),
        (.tidb(version: MySQLEngineVersion(major: 8, minor: 5, patch: 1)), false),
        (.oceanbase(version: nil), false),
        (.databend, false),
        (.starrocks, false),
    ])
    func wrapsOnlyEnforcingFlavors(flavor: MySQLServerFlavor, wraps: Bool) {
        #expect(MySQLReadOnlyTransaction.applies(to: Self.externalRead, flavor: flavor) == wraps)
        #expect(MySQLReadOnlyTransaction.applies(to: Self.safeModeRead, flavor: flavor) == wraps)
        #expect(!MySQLReadOnlyTransaction.applies(to: PluginStatementContext(), flavor: flavor))
        #expect(!MySQLReadOnlyTransaction.applies(to: Self.context(readOnly: true, origin: .app), flavor: flavor))
    }

    @Test("The reason follows who asked: an external read names external clients, anything else at Read-Only names Safe Mode")
    func reasonFollowsTheContext() {
        var catalogRead = Self.context(readOnly: true, origin: .app)
        catalogRead.readsCatalog = true

        #expect(MySQLReadOnlyTransaction.reason(for: Self.externalRead, flavor: .mysql) == .externalClients)
        #expect(MySQLReadOnlyTransaction.reason(for: Self.safeModeRead, flavor: .mariadb) == .safeMode)
        #expect(
            MySQLReadOnlyTransaction.reason(
                for: Self.context(readOnly: true, origin: .external, enforcesReadOnly: true), flavor: .mysql
            ) == .externalClients
        )
        #expect(
            MySQLReadOnlyTransaction.reason(
                for: Self.context(readOnly: false, origin: .external, enforcesReadOnly: true), flavor: .mysql
            ) == .safeMode
        )
        #expect(MySQLReadOnlyTransaction.reason(for: catalogRead, flavor: .mysql) == nil)
    }

    @Test("The driver declares both read-only bits only for a flavor that enforces them")
    func capabilityFollowsFlavor() {
        let capabilities = Self.driver().capabilities
        #expect(capabilities.contains(.readOnlyStatements))
        #expect(capabilities.contains(.enforcesReadOnlyMode))
        for variant in Self.nonEnforcingVariants {
            let other = Self.driver(variant: variant).capabilities
            #expect(!other.contains(.readOnlyStatements), "\(variant)")
            #expect(!other.contains(.enforcesReadOnlyMode), "\(variant)")
        }
    }

    // Nil sends the host back to a call that takes the context; none of these touch the connection.
    @Test("A bounded read the read-only mode cannot cover goes back to the host")
    func boundedReadGoesBackWhenNotCovered() async throws {
        for variant in Self.nonEnforcingVariants {
            let answer = try await Self.driver(variant: variant).executeBoundedQuery(
                query: Self.statement, rowCap: 10, context: Self.safeModeRead
            )
            #expect(answer == nil, "\(variant)")
        }

        var catalogRead = Self.context(readOnly: true, origin: .app)
        catalogRead.readsCatalog = true
        #expect(try await Self.driver().executeBoundedQuery(query: Self.statement, rowCap: 10, context: catalogRead) == nil)
        #expect(
            try await Self.driver().executeBoundedQuery(
                query: Self.statement, rowCap: 10, context: Self.context(readOnly: true, origin: .app)
            ) == nil
        )
    }
}
