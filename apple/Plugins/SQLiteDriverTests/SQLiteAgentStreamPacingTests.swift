//
//  SQLiteAgentStreamPacingTests.swift
//  SQLiteDriverTests
//

import Foundation
import TableProPluginKit
import TableProTestSupport
import Testing

// The shipped agent over a loopback relay, read through the driver's own stream. The agent's watchdog is scaled from
// 60 s to 2 s and the client's heartbeat from 15 s to 0.25 s, so a reader held past the deadline takes seconds.
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SQLiteAgentLoopback.python3Path != nil))
struct SQLiteAgentStreamPacingTests {
    // About 54 MB on the wire, several times what the stream, both loopback sockets (up to 4 MB each) and the pipe hold.
    private static let rowCount = 250_000
    private static let watchdogSeconds = 2.0
    private static let heartbeatSeconds = 0.25

    // Table order with no sort, so the first rows go out at once.
    private static let scan = "SELECT id, payload FROM t ORDER BY rowid"
    // Never ends on its own, so the agent is still reading it whenever the test looks.
    private static let endless =
        "WITH RECURSIVE g(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM g) SELECT x, hex(randomblob(100)) FROM g"

    private static func scaledProgram() throws -> [String] {
        let deadline = "IDLE_DEADLINE_SECONDS = 60.0"
        let poll = "time.sleep(5.0)"
        let source = RemoteSQLiteAgentSource.python
        try #require(source.contains(deadline) && source.contains(poll), "the agent's watchdog constants moved")
        let scaled = source
            .replacingOccurrences(of: deadline, with: "IDLE_DEADLINE_SECONDS = \(watchdogSeconds)")
            .replacingOccurrences(of: poll, with: "time.sleep(0.1)")
        return ["-I", "-S", "-c", scaled]
    }

    private struct Fixture {
        let loopback: SQLiteAgentLoopback
        let driver: SQLitePluginDriver
        let backend: SQLiteAgentBackend
        let path: String
    }

    private static func makeDatabase() async throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("agent-pacing-\(UUID().uuidString).db").path
        let local = SQLitePluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: path
        ))
        try await local.connect()
        _ = try await local.execute(query: """
            CREATE TABLE t AS WITH RECURSIVE g(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM g WHERE x < \(rowCount))
            SELECT x AS id, hex(randomblob(100)) AS payload FROM g
            """)
        local.disconnect()
        return path
    }

    // Closes the session, the agent and the file on every way out, so a failed case leaves no python3 running.
    private static func withAgent(
        arguments: [String] = SQLiteAgentLoopback.shippedArguments,
        heartbeat: TimeInterval = heartbeatSeconds,
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let path = try await makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let loopback = try SQLiteAgentLoopback(arguments: arguments)
        defer { loopback.close() }
        let fields = [SQLiteAgentProtocol.backendFieldKey: SQLiteAgentProtocol.agentBackendValue]
        let backend = SQLiteAgentBackend(
            host: "127.0.0.1",
            port: loopback.port,
            path: path,
            token: loopback.token,
            helloBudget: try #require(SQLiteAgentHelloBudget.forAgent(additionalFields: fields)),
            heartbeatInterval: heartbeat
        )
        let driver = SQLitePluginDriver(
            config: DriverConnectionConfig(
                host: "127.0.0.1", port: loopback.port, username: "", password: "", database: path,
                additionalFields: fields
            ),
            backend: backend
        )
        do {
            try await driver.connect()
            try await body(Fixture(loopback: loopback, driver: driver, backend: backend, path: path))
        } catch {
            await backend.close()
            throw error
        }
        await backend.close()
    }

    private struct NoAnswer: Error {}

    // A statement queued behind a stream that never ends ignores the time limit's cancellation, so it gets its own.
    private static func answer(_ statement: @escaping @Sendable () async throws -> PluginQueryResult) async throws -> String? {
        let result = await BoundedCall.result(within: .seconds(30)) {
            do {
                return Result<PluginQueryResult, Error>.success(try await statement())
            } catch {
                return .failure(error)
            }
        }
        guard let result else { throw NoAnswer() }
        return try result.get().rows.first?.first?.asText
    }

    private static func ids(_ batch: [PluginRow]) -> [Int] {
        batch.compactMap { $0.first?.asText.flatMap(Int.init) }
    }

    // Counts the rows taken and the ids that are not the next one expected.
    private struct OrderedRead {
        var expected = 1
        var mismatches = 0

        mutating func take(_ element: PluginStreamElement) {
            guard case .rows(let batch) = element else { return }
            for id in SQLiteAgentStreamPacingTests.ids(batch) {
                if id != expected { mismatches += 1 }
                expected += 1
            }
        }
    }

    @Test("A reader held past the agent's watchdog gets every row, in order, and the agent's read ends without it")
    func heldReaderOutlastsTheWatchdog() async throws {
        try await Self.withAgent(arguments: try Self.scaledProgram()) { fixture in
            var iterator = fixture.driver.streamRows(query: Self.scan).makeAsyncIterator()
            var read = OrderedRead()
            while read.expected == 1, let element = try await iterator.next() { read.take(element) }

            // The agent read the whole table into the spill, so the connection takes the next statement at once.
            let driver = fixture.driver
            #expect(try await Self.answer { try await driver.execute(query: "SELECT count(*) FROM t") } == String(Self.rowCount))

            // Long enough for the watchdog to have ended the session twice over without heartbeats.
            let heartbeatsBeforeHold = fixture.loopback.heartbeats
            let holdHeartbeats = Int(Self.watchdogSeconds * 2.5 / Self.heartbeatSeconds)
            try await waitUntil(timeout: .seconds(60)) {
                fixture.loopback.heartbeats - heartbeatsBeforeHold >= holdHeartbeats
            }
            #expect(fixture.loopback.agentIsRunning)

            while let element = try await iterator.next() { read.take(element) }
            #expect(read.expected - 1 == Self.rowCount)
            #expect(read.mismatches == 0)
            #expect(try await Self.answer { try await driver.execute(query: "SELECT 42") } == "42")
        }
    }

    @Test("Without heartbeats an idle session outlasts the watchdog and its next statement fails")
    func idleWithoutHeartbeatsLosesTheSession() async throws {
        try await Self.withAgent(arguments: try Self.scaledProgram(), heartbeat: 3_600) { fixture in
            _ = try await fixture.driver.execute(query: "SELECT 1")
            try await waitUntil(timeout: .seconds(30)) { !fixture.loopback.agentIsRunning }

            let driver = fixture.driver
            let failed = await BoundedCall.result(within: .seconds(5)) {
                do {
                    _ = try await driver.execute(query: "SELECT 1")
                    return false
                } catch {
                    return true
                }
            }
            #expect(failed == true)
        }
    }

    @Test("A reader that leaves stops the agent's read, and the next statement gets its own answer")
    func abandonedReadStopsTheAgent() async throws {
        try await Self.withAgent { fixture in
            var iterator: AsyncThrowingStream<PluginStreamElement, Error>.Iterator? =
                fixture.driver.streamRows(query: Self.endless).makeAsyncIterator()
            var rows = 0
            while rows == 0, let element = try await iterator?.next() {
                if case .rows(let batch) = element { rows += batch.count }
            }
            iterator = nil

            let driver = fixture.driver
            #expect(try await Self.answer { try await driver.execute(query: "SELECT 42") } == "42")
            #expect(fixture.loopback.agentIsRunning)
        }
    }

    @Test("A statement sent while the agent is still reading a stream waits for it instead of taking its rows")
    func statementWaitsForTheOpenStream() async throws {
        try await Self.withAgent { fixture in
            var iterator: AsyncThrowingStream<PluginStreamElement, Error>.Iterator? =
                fixture.driver.streamRows(query: Self.endless).makeAsyncIterator()
            var rows = 0
            while rows == 0, let element = try await iterator?.next() {
                if case .rows(let batch) = element { rows += batch.count }
            }

            let driver = fixture.driver
            let statement = Task { try await driver.execute(query: "SELECT 42") }
            // The reader holds, and the agent keeps reading into the spill while the statement stays queued.
            let bytesWhenSent = fixture.loopback.agentBytes
            try await waitUntil(timeout: .seconds(30)) { fixture.loopback.agentBytes > bytesWhenSent + 20_000_000 }
            #expect(fixture.loopback.requests == 1, "the statement went out while the stream was open")

            iterator = nil
            #expect(try await Self.answer { try await statement.value } == "42")
        }
    }

    @Test("An agent that goes away fails the next statement at once instead of ending the app or hanging")
    func agentGoneFailsTheNextStatement() async throws {
        try await Self.withAgent(heartbeat: 0.05) { fixture in
            _ = try await fixture.driver.execute(query: "SELECT 1")

            fixture.loopback.killAgent()
            try await waitUntil { fixture.loopback.clientClosed }

            // The second write to a closed socket raised SIGPIPE, and a request nothing would read waited forever.
            let driver = fixture.driver
            for _ in 0..<3 {
                let failed = await BoundedCall.result(within: .seconds(5)) {
                    do {
                        _ = try await driver.execute(query: "SELECT 1")
                        return false
                    } catch {
                        return true
                    }
                }
                #expect(failed == true)
            }
        }
    }
}
