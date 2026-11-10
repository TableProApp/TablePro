import Foundation
import os
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProTestSupport
import Testing

// The fake server runs each session on its own thread: the first holds the statement, the second is the connection
// the kill arrives on. Its handshake gives the first session thread id 1. Stop is driven as the editor does it: the
// reader leaves its stream, then the driver is asked to cancel.
@Suite(.timeLimit(.minutes(1)))
struct MySQLStopTests {
    private static let held = "UPDATE orders SET archived = 1 WHERE placed_at < '2020-01-01'"
    private static let queuedDelete = "DELETE FROM orders WHERE archived = 1"
    private static let options = StreamOptions(maxRows: 100)

    @Test("Stop sends KILL QUERY for the session's thread over a second connection")
    func stopKillsOnServer() async throws {
        let server = try FakeMySQLServer(identity: nil, holdsQueriesStarting: Self.held)
        defer { server.close() }
        async let sessions = server.serveConcurrently(sessions: 2)
        let driver = Self.driver(port: server.port)
        try await driver.connect()

        let reader = Task { try await Self.read(driver.executeStreaming(query: Self.held, options: Self.options)) }
        try await waitUntil { server.heldQueries == 1 }
        try await Self.stop(reader, on: driver)

        _ = try await driver.execute(query: "SELECT 2")
        try await driver.disconnect()

        let served = await sessions
        #expect(served[1].queries == ["KILL QUERY 1"])
        #expect(Array(served[0].queries.suffix(2)) == [Self.held, "SELECT 2"])
    }

    @Test("A reader that stops kills its own statement on the server")
    func stoppedReaderKills() async throws {
        let server = try FakeMySQLServer(identity: nil, holdsQueriesStarting: Self.held)
        defer { server.close() }
        async let sessions = server.serveConcurrently(sessions: 2)
        let driver = Self.driver(port: server.port)
        try await driver.connect()

        let reader = Task { try await Self.read(driver.executeStreaming(query: Self.held, options: Self.options)) }
        try await waitUntil { server.heldQueries == 1 }
        reader.cancel()

        _ = try await driver.execute(query: "SELECT 2")
        try await driver.disconnect()

        let served = await sessions
        #expect(served[1].queries == ["KILL QUERY 1"])
        #expect(Array(served[0].queries.suffix(2)) == [Self.held, "SELECT 2"])
    }

    @Test("Stop never kills a statement another surface is still reading")
    func stopLeavesAnotherReadersStatement() async throws {
        let server = try FakeMySQLServer(identity: nil, holdsQueriesStarting: Self.held, holdSeconds: 2)
        defer { server.close() }
        async let sessions = server.serveConcurrently(sessions: 2, acceptingWithin: 5_000)
        let driver = Self.driver(port: server.port)
        try await driver.connect()

        let browsing = Task { try await Self.read(driver.executeStreaming(query: Self.held, options: Self.options)) }
        try await waitUntil { server.heldQueries == 1 }
        let editor = Task { try await Self.read(driver.executeStreaming(query: Self.queuedDelete, options: Self.options)) }
        try await Self.stop(editor, on: driver)

        try await browsing.value
        _ = try await driver.execute(query: "SELECT 2")
        try await driver.disconnect()

        let served = await sessions
        #expect(served[1].queries.isEmpty)
        #expect(Array(served[0].queries.suffix(2)) == [Self.held, "SELECT 2"])
    }

    @Test("On TiDB a reader that leaves sends no kill, which would drop the session once the statement ended")
    func tidbReaderExitSendsNoKill() async throws {
        let server = try FakeMySQLServer(identity: nil, holdsQueriesStarting: Self.held, holdSeconds: 2)
        defer { server.close() }
        async let sessions = server.serveConcurrently(sessions: 2, acceptingWithin: 5_000)
        let driver = Self.driver(port: server.port, databaseType: .tidb)
        try await driver.connect()

        let page = Task { try await Self.read(driver.executeStreaming(query: Self.held, options: Self.options)) }
        try await waitUntil { server.heldQueries == 1 }
        page.cancel()

        _ = try await driver.execute(query: "SELECT 2")
        try await driver.disconnect()

        let served = await sessions
        #expect(served[1].queries.isEmpty)
        #expect(Array(served[0].queries.suffix(2)) == [Self.held, "SELECT 2"])
    }

    @Test("On TiDB Stop still kills the statement")
    func tidbStopKills() async throws {
        let server = try FakeMySQLServer(identity: nil, holdsQueriesStarting: Self.held)
        defer { server.close() }
        async let sessions = server.serveConcurrently(sessions: 2)
        let driver = Self.driver(port: server.port, databaseType: .tidb)
        try await driver.connect()

        let reader = Task { try await Self.read(driver.executeStreaming(query: Self.held, options: Self.options)) }
        try await waitUntil { server.heldQueries == 1 }
        try await Self.stop(reader, on: driver)

        _ = try await driver.execute(query: "SELECT 2")
        try await driver.disconnect()

        let served = await sessions
        #expect(served[1].queries == ["KILL QUERY 1"])
        #expect(Array(served[0].queries.suffix(2)) == [Self.held, "SELECT 2"])
    }

    @Test("A kill that lands after its statement finished is taken by a throwaway statement, not the next one")
    func latchedKillIsAbsorbed() async throws {
        let server = try FakeMySQLServer(identity: nil, holdsQueriesStarting: Self.held, killedQueriesComplete: true)
        defer { server.close() }
        async let sessions = server.serveConcurrently(sessions: 2)
        let driver = Self.driver(port: server.port)
        try await driver.connect()

        let reader = Task { try await Self.read(driver.executeStreaming(query: Self.held, options: Self.options)) }
        try await waitUntil { server.heldQueries == 1 }
        try await Self.stop(reader, on: driver)

        _ = try await driver.execute(query: "SELECT 2")
        try await driver.disconnect()

        let served = await sessions
        #expect(served[1].queries == ["KILL QUERY 1"])
        #expect(Array(served[0].queries.suffix(3)) == [Self.held, "SELECT 1", "SELECT 2"])
    }

    @Test("A statement whose reader left while it waited for the session is never sent")
    func abandonedQueuedStatementIsNeverSent() async throws {
        let server = try FakeMySQLServer(identity: nil, holdsQueriesStarting: Self.held)
        defer { server.close() }
        async let sessions = server.serveConcurrently(sessions: 2)
        let driver = Self.driver(port: server.port)
        try await driver.connect()

        let running = Task { try await Self.read(driver.executeStreaming(query: Self.held, options: Self.options)) }
        try await waitUntil { server.heldQueries == 1 }
        let queued = Task { try await Self.read(driver.executeStreaming(query: Self.queuedDelete, options: Self.options)) }
        queued.cancel()
        _ = await queued.result
        running.cancel()

        _ = try await driver.execute(query: "SELECT 2")
        try await driver.disconnect()

        let served = await sessions
        #expect(served[1].queries == ["KILL QUERY 1"])
        #expect(!served[0].queries.contains(Self.queuedDelete))
        #expect(served[0].queries.last == "SELECT 2")
    }

    @Test("A young session token signs the kill in without waiting on a mint")
    func youngSessionTokenServesTheKill() async throws {
        let mints = OSAllocatedUnfairLock(initialState: 0)
        let served = try await Self.killTokenSessions(sessionAge: .seconds(60)) {
            mints.withLock { $0 += 1 }
            return "kill-token"
        }
        let minted = mints.withLock { $0 }

        #expect(served[1].cleartextPassword == "connect-token")
        #expect(served[1].queries == ["KILL QUERY 1"])
        #expect(minted == 0)
    }

    @Test("Past ten minutes a kill signs in with a token minted for it, not the one the session signed in with")
    func killMintsAFreshToken() async throws {
        let served = try await Self.killTokenSessions(sessionAge: .seconds(601)) { "kill-token" }

        #expect(served[0].cleartextPassword == "connect-token")
        #expect(served[1].cleartextPassword == "kill-token")
        #expect(served[1].encrypted)
        #expect(served[1].queries == ["KILL QUERY 1"])
    }

    @Test("A mint that fails leaves the kill the token the session signed in with")
    func failedMintKeepsSessionToken() async throws {
        let served = try await Self.killTokenSessions(sessionAge: .seconds(601)) { throw MintFailure() }

        #expect(served[1].cleartextPassword == "connect-token")
        #expect(served[1].queries == ["KILL QUERY 1"])
    }

    // The tunnel and its prompts come before the connect the reuse is timed from, so a young-looking token can be
    // expired; the server's 1045 sends the kill back for one mint.
    @Test("A reused token the server refuses is minted once and the kill signs in again")
    func refusedReusedTokenIsMintedOnce() async throws {
        let mints = OSAllocatedUnfairLock(initialState: 0)
        let served = try await Self.killTokenSessions(
            sessionAge: .seconds(60), refusing: "connect-token", sessions: 3
        ) {
            mints.withLock { $0 += 1 }
            return "kill-token"
        }
        let minted = mints.withLock { $0 }

        #expect(served[1].cleartextPassword == "connect-token")
        #expect(!served[1].loggedIn)
        #expect(served[2].cleartextPassword == "kill-token")
        #expect(served[2].queries == ["KILL QUERY 1"])
        #expect(minted == 1)
    }

    @Test("A token minted for the kill that the server refuses is not tried again")
    func refusedMintedTokenIsNotRetried() async throws {
        let mints = OSAllocatedUnfairLock(initialState: 0)
        let served = try await Self.killTokenSessions(
            sessionAge: .seconds(601), refusing: "kill-token", sessions: 3, acceptingWithin: 5_000
        ) {
            mints.withLock { $0 += 1 }
            return "kill-token"
        }
        let minted = mints.withLock { $0 }

        #expect(served[1].cleartextPassword == "kill-token")
        #expect(!served[1].loggedIn)
        #expect(!served[2].sawLogin)
        #expect(minted == 1)
    }

    private struct MintFailure: Error {}

    private static func killTokenSessions(
        sessionAge: Duration,
        refusing refusedPassword: String? = nil,
        sessions count: Int = 2,
        acceptingWithin milliseconds: Int32? = nil,
        refresh: @escaping @Sendable () async throws -> String?
    ) async throws -> [FakeMySQLServer.Session] {
        let server = try FakeMySQLServer(identity: .localhost, asksForCleartext: true, holdsQueriesStarting: Self.held)
        defer { server.close() }
        async let sessions = server.serveConcurrently(sessions: count, acceptingWithin: milliseconds)
        let clock = ManualClock()
        let driver = MySQLDriver(
            host: "127.0.0.1", port: server.port, user: "iam_user", password: "connect-token", database: "",
            ssl: DriverSSLConfiguration(mode: .require), signsInWithToken: true, refreshPassword: refresh,
            clock: clock
        )
        try await driver.connect()
        if let refusedPassword {
            server.refuse(refusedPassword)
        }
        clock.advance(by: sessionAge)

        let reader = Task { try await Self.read(driver.executeStreaming(query: Self.held, options: Self.options)) }
        try await waitUntil { server.heldQueries == 1 }
        reader.cancel()

        _ = try await driver.execute(query: "SELECT 2")
        try await driver.disconnect()
        return await sessions
    }

    private static func driver(port: Int, databaseType: DatabaseType = .mysql) -> MySQLDriver {
        MySQLDriver(
            host: "127.0.0.1", port: port, user: "app", password: "app-password", database: "",
            databaseType: databaseType
        )
    }

    private static func stop(_ reader: Task<Void, Error>, on driver: MySQLDriver) async throws {
        reader.cancel()
        _ = await reader.result
        try await driver.cancelCurrentQuery()
    }

    private static func read(_ stream: AsyncThrowingStream<StreamElement, Error>) async throws {
        for try await _ in stream {}
    }
}

struct MySQLKillRequestsTests {
    @Test("A kill is taken only for the statement in flight, and once")
    func killOnlyInFlight() {
        var requests = MySQLKillRequests()
        let first = requests.reserve()
        let second = requests.reserve()
        let beforeSending = requests.kill(first)

        requests.sent(first)
        let otherStatement = requests.kill(second)
        let inFlight = requests.kill(first)
        let again = requests.kill(first)
        requests.readerLeft(first)
        let stopAgain = requests.killLeftInFlight()

        #expect(!beforeSending)
        #expect(!otherStatement)
        #expect(inFlight)
        #expect(!again)
        #expect(stopAgain == nil)
    }

    @Test("Stop takes only the statement in flight whose reader left last")
    func stopTakesOnlyTheLeftStatement() {
        var requests = MySQLKillRequests()
        let browsing = requests.reserve()
        let editor = requests.reserve()
        requests.sent(browsing)
        let whileRead = requests.killLeftInFlight()

        requests.readerLeft(editor)
        let editorQueued = requests.killLeftInFlight()

        requests.readerLeft(browsing)
        let browsingLeft = requests.killLeftInFlight()

        #expect(whileRead == nil)
        #expect(editorQueued == nil)
        #expect(browsingLeft == browsing)
    }

    @Test("A statement that ended takes no kill, so a late Stop never reaches the next one")
    func endedStatementTakesNoKill() {
        var requests = MySQLKillRequests()
        let first = requests.reserve()
        requests.sent(first)
        requests.readerLeft(first)
        requests.finished(first, interrupted: false)
        let stop = requests.killLeftInFlight()
        let streamEnd = requests.kill(first)

        let second = requests.reserve()
        requests.sent(second)
        requests.finished(first, interrupted: false)

        #expect(stop == nil)
        #expect(!streamEnd)
        #expect(requests.isInFlight(second))
    }

    @Test("Only a delivered kill its statement did not collect is left for the next statement")
    func latchedKill() {
        var requests = MySQLKillRequests()
        let first = requests.reserve()
        requests.sent(first)
        requests.delivered(first)
        requests.finished(first, interrupted: false)
        let latched = requests.takeLatchedKill()
        let latchedAgain = requests.takeLatchedKill()

        let second = requests.reserve()
        requests.sent(second)
        requests.finished(second, interrupted: true)
        requests.delivered(second)
        let collected = requests.takeLatchedKill()

        let third = requests.reserve()
        requests.sent(third)
        requests.finished(third, interrupted: false)
        let neverKilled = requests.takeLatchedKill()

        #expect(latched)
        #expect(!latchedAgain)
        #expect(!collected)
        #expect(!neverKilled)
    }

    @Test("A closed session forgets its kills")
    func detachForgets() {
        var requests = MySQLKillRequests()
        let first = requests.reserve()
        requests.sent(first)
        requests.delivered(first)
        requests.detach()
        let latched = requests.takeLatchedKill()

        #expect(!requests.isInFlight(first))
        #expect(!latched)
    }

    @Test("Each engine gets the kill that stops only the statement")
    func killStatements() {
        #expect(Self.kill(.mysql, banner: "8.4.11", thread: 42) == "KILL QUERY 42")
        #expect(Self.kill(.mariadb, banner: "10.6.28-MariaDB", thread: 42) == "KILL QUERY 42")
        #expect(Self.kill(.mysql, banner: "5.0.96", thread: 42) == "KILL QUERY 42")
        #expect(Self.kill(.oceanbase, banner: "5.7.25-OceanBase_CE-v4.2.1.0", thread: 42) == "KILL QUERY 42")
        #expect(Self.kill(.tidb, banner: "8.0.11-TiDB-v8.5.0", thread: 42, tidb: 2_199_023_255_553)
            == "KILL TIDB QUERY 2199023255553")
        #expect(Self.kill(.mysql, banner: "8.4.11", thread: 0) == nil)
    }

    @Test("A server that can only end the session, and Databend, get no kill")
    func noKill() {
        #expect(Self.kill(.mysql, banner: "4.1.22", thread: 42) == nil)
        #expect(Self.kill(.mysql, banner: "8.0.17-v1.2.615-nightly", thread: 42) == nil)
    }

    @Test("Only MySQL and MariaDB pay a round trip to collect a kill that landed late")
    func absorbingEngines() {
        #expect(MySQLKillStatement.absorbsLatchedKill(flavor: .mysql))
        #expect(MySQLKillStatement.absorbsLatchedKill(flavor: .mariadb))
        #expect(!MySQLKillStatement.absorbsLatchedKill(flavor: .tidb(version: nil)))
        #expect(!MySQLKillStatement.absorbsLatchedKill(flavor: .oceanbase(version: nil)))
        #expect(!MySQLKillStatement.absorbsLatchedKill(flavor: .databend))
    }

    private static func kill(_ type: DatabaseType, banner: String, thread: UInt, tidb: UInt64? = nil) -> String? {
        MySQLKillStatement.text(
            flavor: MySQLDriver.serverFlavor(for: type, banner: banner),
            banner: banner,
            threadId: thread,
            tidbConnectionId: tidb
        )
    }
}
