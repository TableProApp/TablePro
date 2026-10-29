import Foundation
import Testing

@testable import TablePro

/// The heartbeat's first-query timestamp lost its only caller when `DatabaseManager.execute(query:)`
/// was removed, so it stayed nil on every Mac. Recording an editor run's history is where it is set now.
@MainActor
struct FirstQueryAnalyticsTests {
    private func request(_ source: QueryHistorySource, succeeded: Bool, connectionId: UUID) -> QueryHistoryRecordRequest {
        QueryHistoryRecordRequest(
            query: "SELECT 1",
            connectionId: connectionId,
            databaseName: "db",
            databaseType: .postgresql,
            source: source,
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: succeeded,
            errorMessage: succeeded ? nil : "syntax error"
        )
    }

    // The mark is written before recordHistory returns its task, so every assertion runs before the
    // first suspension and no other suite can touch the shared defaults in between.
    @Test("Only a successful editor query records the first-query timestamp")
    func successfulEditorQueryMarksFirstQuery() async {
        AppStorageEnvironment.shared.defaults.removeObject(forKey: MacAnalyticsProvider.Keys.firstQueryExecutedAt)
        let fixture = CoordinatorFixture()
        let connectionId = fixture.connection.id

        let failed = fixture.coordinator.recordHistory(request(.editor, succeeded: false, connectionId: connectionId))
        let browsed = fixture.coordinator.recordHistory(request(.tableBrowse, succeeded: true, connectionId: connectionId))
        #expect(MacAnalyticsProvider.shared.firstQueryExecutedAt == nil)

        let ran = fixture.coordinator.recordHistory(request(.editor, succeeded: true, connectionId: connectionId))
        #expect(MacAnalyticsProvider.shared.firstQueryExecutedAt != nil)

        _ = await (failed.value, browsed.value, ran.value)
    }
}
