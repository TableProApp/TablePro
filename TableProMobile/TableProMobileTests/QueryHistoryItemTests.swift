import Foundation
import Testing
@testable import TableProMobile

@Suite("QueryHistoryItem")
struct QueryHistoryItemTests {
    @Test("a query that failed is recorded as failed")
    func failureIsRecorded() {
        let item = QueryHistoryItem(
            query: "SELECT * FROM missing",
            connectionId: UUID(),
            wasSuccessful: false,
            errorMessage: "no such table"
        )
        #expect(item.wasSuccessful == false)
        #expect(item.errorMessage == "no such table")
    }

    @Test("a query defaults to successful, so existing call sites keep their meaning")
    func successIsTheDefault() {
        let item = QueryHistoryItem(query: "SELECT 1", connectionId: UUID())
        #expect(item.wasSuccessful)
        #expect(item.errorMessage == nil)
    }

    @Test("history written before outcomes were recorded still decodes")
    func legacyItemDecodes() throws {
        let legacy = """
            {
                "id": "\(UUID().uuidString)",
                "query": "SELECT 1",
                "timestamp": 750000000,
                "connectionId": "\(UUID().uuidString)"
            }
            """
        let data = try #require(legacy.data(using: .utf8))
        let decoded = try JSONDecoder().decode(QueryHistoryItem.self, from: data)

        #expect(decoded.query == "SELECT 1")
        #expect(decoded.wasSuccessful, "An entry written before outcomes existed is not a failure")
        #expect(decoded.errorMessage == nil)
    }

    @Test("an outcome survives a round trip")
    func outcomeRoundTrips() throws {
        let item = QueryHistoryItem(
            query: "DELETE FROM t",
            connectionId: UUID(),
            wasSuccessful: false,
            errorMessage: "permission denied"
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(QueryHistoryItem.self, from: data)

        #expect(decoded.wasSuccessful == false)
        #expect(decoded.errorMessage == "permission denied")
    }
}
