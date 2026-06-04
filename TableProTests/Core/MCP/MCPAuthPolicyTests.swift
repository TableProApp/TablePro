import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("MCPAuthPolicy")
struct MCPAuthPolicyTests {
    @Test("logQuery skips history when logging is disabled")
    func logQuerySkipsHistoryWhenDisabled() async {
        var recordedEntries: [QueryHistoryEntry] = []
        let policy = MCPAuthPolicy(
            defaultConnectionPolicyProvider: { .askEachTime },
            logQueriesInHistoryProvider: { false },
            queryHistoryRecorder: { entry in
                recordedEntries.append(entry)
            }
        )

        await policy.logQuery(
            sql: "SELECT 1",
            connectionId: UUID(),
            databaseName: "main",
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true,
            errorMessage: nil
        )

        #expect(recordedEntries.isEmpty)
    }

    @Test("logQuery records history when logging is enabled")
    func logQueryRecordsHistoryWhenEnabled() async throws {
        var recordedEntries: [QueryHistoryEntry] = []
        let connectionId = UUID()
        let policy = MCPAuthPolicy(
            defaultConnectionPolicyProvider: { .askEachTime },
            logQueriesInHistoryProvider: { true },
            queryHistoryRecorder: { entry in
                recordedEntries.append(entry)
            }
        )

        await policy.logQuery(
            sql: "SELECT * FROM users",
            connectionId: connectionId,
            databaseName: "analytics",
            executionTime: 0.25,
            rowCount: 5,
            wasSuccessful: true,
            errorMessage: nil
        )

        let entry = try #require(recordedEntries.first)
        #expect(recordedEntries.count == 1)
        #expect(entry.query == "SELECT * FROM users")
        #expect(entry.connectionId == connectionId)
        #expect(entry.databaseName == "analytics")
        #expect(entry.executionTime == 0.25)
        #expect(entry.rowCount == 5)
        #expect(entry.wasSuccessful)
    }
}
