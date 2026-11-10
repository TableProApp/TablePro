import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct TableHealthReportLoaderTests {
    @Test("Cancelling a report read on the cancellable lease stops its statement on the server", .timeLimit(.minutes(1)))
    func cancelStopsTheStatementOnTheServer() async throws {
        let connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)
        let plugin = HeldCatalogDriver()
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: connection, driver: PluginDriverAdapter(connection: connection, pluginDriver: plugin)),
            for: connection.id
        )
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: nil)
        // Only the bulk lane has a connection, so the read has to lease there.
        let pooled = PluginDriverAdapter(connection: connection, pluginDriver: plugin)
        try await pooled.connect()
        MetadataConnectionPool.shared.injectEntry(pooled, scope: scope, workload: .bulk)
        defer {
            MetadataConnectionPool.shared.closeAll(connectionId: connection.id)
            DatabaseManager.shared.removeSession(for: connection.id)
        }

        let load = Task {
            try await TableHealthReportLoader.load(provider: OneCheckProvider(), scope: scope, lease: .cancellable)
        }
        await plugin.reached.wait()
        load.cancel()
        await plugin.cancelled.wait()
        _ = await load.result

        #expect(plugin.cancelCount == 1)
        #expect(DatabaseManager.shared.runningDrivers[connection.id] == nil)
    }
}

private struct OneCheckProvider: TableHealthProvider {
    var checks: [TableHealthCheckKind] { [.missingPrimaryKey] }
    var statisticsQueries: [String] { [] }

    func statistics(from results: [QueryResult?], now: Date) -> TableHealthStatistics {
        TableHealthStatistics()
    }

    func check(_ kind: TableHealthCheckKind) -> TableHealthCheck {
        TableHealthCheck(kind: kind, summary: "")
    }

    func queries(for check: TableHealthCheckKind, statistics: TableHealthStatistics) -> [String] {
        ["SELECT 1"]
    }

    func findings(
        for check: TableHealthCheckKind,
        from results: [QueryResult],
        context: TableHealthQueryContext,
        statistics: TableHealthStatistics
    ) -> (findings: [TableHealthFinding], note: String?) {
        ([], nil)
    }
}

private struct CancelledOnServer: Error {}

// Holds every statement until the server is told to cancel it, the way a slow catalog read on a large database does.
private final class HeldCatalogDriver: PluginDriverStub, @unchecked Sendable {
    let reached = AsyncGate()
    let cancelled = AsyncGate()
    private let lock = NSLock()
    private var pending: CheckedContinuation<Void, any Error>?
    private var cancels = 0

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancels
    }

    func execute(query: String, context: PluginStatementContext) async throws -> PluginQueryResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            pending = continuation
            lock.unlock()
            Task { await reached.open() }
        }
        return .empty
    }

    func cancelQuery() throws {
        lock.lock()
        cancels += 1
        let continuation = pending
        pending = nil
        lock.unlock()
        continuation?.resume(throwing: CancelledOnServer())
        Task { await cancelled.open() }
    }
}
