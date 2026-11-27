//
//  MySQLStopBeforeStatementTests.swift
//  MySQLDriverTests
//

import Foundation
import TableProPluginKit
import Testing

// Stop reaches a statement through its cancellation generation, which the connection opens only on its queue. A Stop
// that lands after the driver took a user statement and before that must still keep the statement from going out.
@Suite(.timeLimit(.minutes(1)))
struct MySQLStopBeforeStatementTests {
    private final class StopBox: @unchecked Sendable {
        private let lock = NSLock()
        private var driver: MySQLPluginDriver?

        func arm(_ driver: MySQLPluginDriver) {
            lock.withLock { self.driver = driver }
        }

        func stopOnce() {
            let armed = lock.withLock { () -> MySQLPluginDriver? in
                defer { driver = nil }
                return driver
            }
            try? armed?.cancelQuery()
        }
    }

    // Connection id 0 leaves Stop no thread to kill, so it never dials a second connection this server cannot answer.
    private static func server(stoppingAt statement: @escaping @Sendable (String) -> Bool, box: StopBox) throws
        -> PlaintextMySQLServer {
        try PlaintextMySQLServer(asksForCleartext: false, connectionId: 0, onQuery: { query in
            if statement(query) { box.stopOnce() }
        })
    }

    private static func driver(port: Int) -> MySQLPluginDriver {
        MySQLPluginDriver(config: DriverConnectionConfig(
            host: "127.0.0.1",
            port: port,
            username: "app",
            password: "app-password",
            database: "",
            ssl: SSLConfiguration(mode: .disabled)
        ))
    }

    @Test("A Stop while the driver takes its released connection back sends none of the statement")
    func stopDuringReacquireSendsNothing() async throws {
        let box = StopBox()
        let server = try Self.server(stoppingAt: { $0.hasPrefix("SET NAMES") }, box: box)
        defer { server.close() }
        async let sessions = server.serve(sessions: 2)
        let driver = Self.driver(port: server.port)
        try await driver.connect()
        _ = try await driver.releaseIdleResource()
        box.arm(driver)

        var failure: Error?
        do {
            _ = try await driver.executeUserQuery(
                query: "SELECT 'stopped'", rowCap: nil, parameters: nil, context: PluginStatementContext()
            )
        } catch {
            failure = error
        }
        _ = try await driver.executeUserQuery(
            query: "SELECT 'next'", rowCap: nil, parameters: nil, context: PluginStatementContext()
        )
        driver.disconnect()

        let queries = await sessions.last?.queries ?? []
        #expect(failure is CancellationError)
        #expect(queries.contains { $0.hasPrefix("SET NAMES") })
        #expect(!queries.contains("SELECT 'stopped'"))
        #expect(queries.contains("SELECT 'next'"))
    }

    @Test("A Stop during the read-only mode's begin sends none of the statement and still rolls the begin back")
    func stopDuringReadOnlyBeginSendsNothing() async throws {
        let box = StopBox()
        let server = try Self.server(stoppingAt: { $0 == "START TRANSACTION READ ONLY" }, box: box)
        defer { server.close() }
        async let session = server.serveOneSession()
        let driver = Self.driver(port: server.port)
        try await driver.connect()
        box.arm(driver)

        var failure: Error?
        do {
            _ = try await driver.executeUserQuery(
                query: "SELECT 'stopped'",
                rowCap: nil,
                parameters: nil,
                context: PluginStatementContext(enforcesReadOnly: true)
            )
        } catch {
            failure = error
        }
        driver.disconnect()

        let queries = await session.queries
        #expect(failure is CancellationError)
        #expect(queries.contains("START TRANSACTION READ ONLY"))
        #expect(!queries.contains("SELECT 'stopped'"))
        #expect(queries.last == "ROLLBACK")
    }

    @Test("A statement a Stop held back releases nothing the session holds")
    func heldBackStatementKeepsTheFootprint() async throws {
        let box = StopBox()
        let server = try Self.server(stoppingAt: { $0 == "START TRANSACTION READ ONLY" }, box: box)
        defer { server.close() }
        async let session = server.serveOneSession()
        let driver = Self.driver(port: server.port)
        try await driver.connect()
        _ = try await driver.executeUserQuery(
            query: "SELECT GET_LOCK('job', 1)", rowCap: nil, parameters: nil, context: PluginStatementContext()
        )
        box.arm(driver)

        var failure: Error?
        do {
            _ = try await driver.executeUserQuery(
                query: "SELECT RELEASE_ALL_LOCKS()",
                rowCap: nil,
                parameters: nil,
                context: PluginStatementContext(enforcesReadOnly: true)
            )
        } catch {
            failure = error
        }
        let release = try await driver.releaseIdleResource()
        driver.disconnect()

        let queries = await session.queries
        #expect(failure is CancellationError)
        #expect(!queries.contains("SELECT RELEASE_ALL_LOCKS()"))
        #expect(!release.didRelease)
    }
}
