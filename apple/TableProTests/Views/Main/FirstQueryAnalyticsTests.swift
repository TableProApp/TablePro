import Foundation
import Testing

@testable import TablePro

/// The first-query mark lost its only caller when `DatabaseManager.execute(query:)` was removed, so it
/// was never sent. Recording an editor run's history is where telemetry hears of it now.
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
    @Test("Only a successful editor query marks the first query")
    func successfulEditorQueryMarksFirstQuery() async {
        let defaults = AppStorageEnvironment.shared.defaults
        defaults.removeObject(forKey: Telemetry.Keys.firstQueryExecutedAt)
        let fixture = CoordinatorFixture()
        let connectionId = fixture.connection.id

        let failed = fixture.coordinator.recordHistory(request(.editor, succeeded: false, connectionId: connectionId))
        let browsed = fixture.coordinator.recordHistory(request(.tableBrowse, succeeded: true, connectionId: connectionId))
        #expect(defaults.object(forKey: Telemetry.Keys.firstQueryExecutedAt) == nil)

        let ran = fixture.coordinator.recordHistory(request(.editor, succeeded: true, connectionId: connectionId))
        #expect(defaults.object(forKey: Telemetry.Keys.firstQueryExecutedAt) != nil)

        _ = await (failed.value, browsed.value, ran.value)
    }
}
