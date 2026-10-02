import Foundation
import TableProPluginKit
import Testing

struct ClickHouseCancelQueryTests {
    private static let heldStatement = "SELECT sleep(3)"

    private static func holdingTheHeldStatement() -> ClickHouseStubServer {
        ClickHouseStubServer { request in
            request.body == heldStatement ? nil : .oneRow
        }
    }

    private func stopKillsTheHeldStatement(
        on server: ClickHouseStubServer,
        driver: ClickHousePluginDriver
    ) async throws {
        let streamed = try #require(await server.firstRequest { $0.body == Self.heldStatement })
        let queryId = try #require(streamed.item("query_id"))
        #expect(!queryId.isEmpty)

        try driver.cancelQuery()

        let kill = try #require(await server.firstRequest { $0.body.hasPrefix("KILL QUERY") })
        #expect(kill.body == "KILL QUERY WHERE query_id = '\(queryId)'")
        #expect(kill.item("max_execution_time") == nil)
    }

    @Test("Stop on a capped query kills that query on the server, not the statement before it")
    func stopKillsBoundedStream() async throws {
        let server = Self.holdingTheHeldStatement()
        let driver = server.connectedDriver()
        try await driver.applyQueryTimeout(120)
        _ = try await driver.execute(query: "SELECT 0")
        let earlierId = try #require(server.requests.first { $0.body == "SELECT 0" }?.item("query_id"))

        let query = Task { try await driver.executeBoundedQuery(query: Self.heldStatement, rowCap: 10) }
        defer { query.cancel() }

        try await stopKillsTheHeldStatement(on: server, driver: driver)
        let kill = try #require(server.requests.first { $0.body.hasPrefix("KILL QUERY") })
        #expect(!kill.body.contains(earlierId))
    }

    @Test("Stop on an unbounded streamed read kills that read on the server")
    func stopKillsUnboundedStream() async throws {
        let server = Self.holdingTheHeldStatement()
        let driver = server.connectedDriver()

        let read = Task {
            for try await _ in driver.streamRows(query: Self.heldStatement) {}
        }
        defer { read.cancel() }

        try await stopKillsTheHeldStatement(on: server, driver: driver)
    }

    @Test("Each streamed statement gets its own query id")
    func streamedStatementsGetDistinctIds() async throws {
        let server = ClickHouseStubServer()
        let driver = server.connectedDriver()

        _ = try await driver.executeBoundedQuery(query: "SELECT 1", rowCap: 10)
        _ = try await driver.executeBoundedQuery(query: "SELECT 2", rowCap: 10)

        let ids = server.requests.compactMap { $0.item("query_id") }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
    }
}
