import Foundation
import TableProPluginKit
import Testing

struct ClickHouseQueryTimeoutTests {
    @Test("The query timeout rides every statement as max_execution_time, streamed reads included")
    func timeoutReachesEveryStatement() async throws {
        let server = ClickHouseStubServer()
        let driver = server.connectedDriver()

        try await driver.applyQueryTimeout(120)
        _ = try await driver.execute(query: "SELECT 1")
        _ = try await driver.executeParameterized(query: "SELECT ?", parameters: [.text("a")])
        _ = try await driver.executeBoundedQuery(query: "SELECT 2", rowCap: 10)

        let requests = server.requests
        #expect(requests.count >= 3)
        for request in requests {
            #expect(request.item("max_execution_time") == "120", "\(request.body)")
            #expect(!request.body.uppercased().hasPrefix("SET "), "\(request.body)")
        }
    }

    @Test("A streamed read waits as long as the query timeout allows, not URLRequest's 60 seconds")
    func streamedReadTakesTheClientTimeout() async throws {
        let server = ClickHouseStubServer()
        let driver = server.connectedDriver()

        try await driver.applyQueryTimeout(120)
        _ = try await driver.executeBoundedQuery(query: "SELECT 2", rowCap: 10)
        try await driver.applyQueryTimeout(0)
        _ = try await driver.executeBoundedQuery(query: "SELECT 3", rowCap: 10)

        let bounded = try #require(server.requests.first { $0.body == "SELECT 2" })
        #expect(bounded.timeoutInterval == HttpQueryTimeout(serverTimeoutSeconds: 120).requestTimeoutInterval)
        let unlimited = try #require(server.requests.first { $0.body == "SELECT 3" })
        #expect(unlimited.timeoutInterval == HttpQueryTimeout(serverTimeoutSeconds: 0).requestTimeoutInterval)
        #expect(unlimited.item("max_execution_time") == nil)
    }

    @Test("No query timeout sends no max_execution_time, so the server's own profile limit stands")
    func noTimeoutSendsNoLimit() async throws {
        let server = ClickHouseStubServer()
        let driver = server.connectedDriver()

        try await driver.applyQueryTimeout(0)
        _ = try await driver.execute(query: "SELECT 1")

        #expect(server.requests.allSatisfy { $0.item("max_execution_time") == nil })
    }

    @Test("A limit the server refuses is reported once and left off every later statement")
    func refusedLimitIsNotSentAgain() async throws {
        let refusal = "Code: 452. DB::Exception: Setting max_execution_time shouldn't be greater than 30."
        let server = ClickHouseStubServer { request in
            request.item("max_execution_time") == nil ? .oneRow : ClickHouseStubReply(statusCode: 500, body: refusal)
        }
        let driver = server.connectedDriver()

        await #expect(throws: ClickHouseError.self) {
            try await driver.applyQueryTimeout(120)
        }
        let result = try await driver.execute(query: "SELECT 10")
        _ = try await driver.executeBoundedQuery(query: "SELECT 20", rowCap: 10)

        #expect(result.rows.count == 1)
        let later = server.requests.filter { $0.body == "SELECT 10" || $0.body == "SELECT 20" }
        #expect(later.count == 2)
        #expect(later.allSatisfy { $0.item("max_execution_time") == nil })
    }
}
