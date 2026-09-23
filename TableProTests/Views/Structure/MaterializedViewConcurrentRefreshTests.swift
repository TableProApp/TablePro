//
//  MaterializedViewConcurrentRefreshTests.swift
//  TableProTests
//
//  A materialized view's Indexes tab says whether the view can be refreshed without blocking its
//  readers, and the answer comes from the server rather than from the index list: an index left
//  INVALID by a failed concurrent build lists exactly like a valid one. (#2522)
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct ProbeFailure: Error {}

@MainActor
private final class ConcurrentRefreshProvider: ScopedMetadataProviding {
    private(set) var requestedScopes: [DatabaseScope] = []
    let driver: MockDatabaseDriver

    init(driver: MockDatabaseDriver = MockDatabaseDriver()) {
        self.driver = driver
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        requestedScopes.append(scope)
        return try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? { nil }
}

@Suite("Materialized view concurrent refresh note")
struct MaterializedViewConcurrentRefreshNoteTests {
    @Test("Nothing is shown before the server has answered")
    func nothingBeforeAnAnswer() {
        #expect(MaterializedViewConcurrentRefreshNote(state: .idle) == nil)
        #expect(MaterializedViewConcurrentRefreshNote(state: .loading) == nil)
    }

    @Test("An engine with no concurrent refresh shows nothing at all")
    func nothingWhereTheEngineHasNoConcurrentRefresh() {
        #expect(MaterializedViewConcurrentRefreshNote(state: .loaded(nil)) == nil)
    }

    @Test("A qualifying view says it can be refreshed concurrently")
    func availableSaysSo() throws {
        let note = try #require(MaterializedViewConcurrentRefreshNote(state: .loaded(.available)))
        #expect(note.systemImage == "checkmark.circle")
        #expect(note.text == String(localized: "This view can be refreshed concurrently."))
    }

    @Test("A view without a usable unique index names what it needs")
    func missingUniqueIndexNamesTheRequirement() throws {
        let note = try #require(MaterializedViewConcurrentRefreshNote(state: .loaded(.requiresUniqueIndex)))
        #expect(note.systemImage == "info.circle")
        #expect(note.text.contains("unique index"))
        #expect(note.text.contains("WHERE"))
    }

    /// Measured on PostgreSQL 17.11: a view refreshed over a query that returns nothing is populated
    /// with zero rows, and `REFRESH … CONCURRENTLY` then succeeds, so the condition is never "rows".
    @Test("An unpopulated view says it needs populating first, not an index")
    func unpopulatedViewNeedsPopulating() throws {
        let note = try #require(MaterializedViewConcurrentRefreshNote(state: .loaded(.requiresPopulatedView)))
        #expect(note.systemImage == "info.circle")
        #expect(note.text.contains("populated"))
        #expect(!note.text.contains("rows"))
        #expect(!note.text.contains("unique index"))
    }

    @Test("A check that failed says so rather than guessing")
    func failedCheckSaysSo() throws {
        let note = try #require(MaterializedViewConcurrentRefreshNote(state: .failed("timeout")))
        #expect(note.systemImage == "exclamationmark.triangle")
        #expect(note.text.contains("Couldn't check"))
    }
}

@Suite("Materialized view concurrent refresh check", .serialized)
@MainActor
struct MaterializedViewConcurrentRefreshCheckTests {
    private static func makeSession(
        kind: TableInfo.TableType,
        schema: String? = "reporting"
    ) -> StructureEditingSession {
        let connection = TestFixtures.makeConnection(database: "analytics", type: .postgresql)
        return StructureEditingSession(
            identity: "analytics.\(schema ?? "").daily_totals",
            connection: connection,
            databaseName: "analytics",
            schemaName: schema,
            tableName: "daily_totals",
            objectKind: kind
        )
    }

    @Test("A materialized view asks the server about its own name, schema and scope")
    func asksAboutTheViewItself() async {
        let session = Self.makeSession(kind: .materializedView)
        let provider = ConcurrentRefreshProvider()
        provider.driver.concurrentRefreshAvailabilityToReturn = .available

        await session.reloadConcurrentRefreshAvailability(provider: provider)

        #expect(session.concurrentRefresh == .loaded(.available))
        #expect(provider.driver.concurrentRefreshAvailabilityCalls.map(\.name) == ["daily_totals"])
        #expect(provider.driver.concurrentRefreshAvailabilityCalls.map(\.schema) == ["reporting"])
        #expect(provider.requestedScopes == [session.scope])
    }

    @Test("A table, a view and a partitioned table never ask")
    func otherKindsNeverAsk() async {
        for kind: TableInfo.TableType in [.table, .view, .partitionedTable, .foreignTable] {
            let session = Self.makeSession(kind: kind)
            let provider = ConcurrentRefreshProvider()

            await session.reloadConcurrentRefreshAvailability(provider: provider)

            #expect(provider.driver.concurrentRefreshAvailabilityCalls.isEmpty, "\(kind.rawValue)")
            #expect(session.concurrentRefresh == .idle, "\(kind.rawValue)")
        }
    }

    @Test("A recheck replaces the answer, so an index added since shows up")
    func recheckReplacesTheAnswer() async {
        let session = Self.makeSession(kind: .materializedView)
        let provider = ConcurrentRefreshProvider()
        provider.driver.concurrentRefreshAvailabilityToReturn = .requiresUniqueIndex
        await session.reloadConcurrentRefreshAvailability(provider: provider)
        #expect(session.concurrentRefresh == .loaded(.requiresUniqueIndex))

        provider.driver.concurrentRefreshAvailabilityToReturn = .available
        await session.reloadConcurrentRefreshAvailability(provider: provider)

        #expect(session.concurrentRefresh == .loaded(.available))
    }

    /// The recheck runs after the index list has already been refetched, so an old answer kept over
    /// a failure can contradict the indexes on screen: a view whose only unique index was just dropped
    /// would go on reading "can be refreshed concurrently".
    @Test("A failed recheck says it could not check rather than repeating the old answer")
    func failedRecheckReportsTheFailure() async {
        let session = Self.makeSession(kind: .materializedView)
        let provider = ConcurrentRefreshProvider()
        provider.driver.concurrentRefreshAvailabilityToReturn = .available
        await session.reloadConcurrentRefreshAvailability(provider: provider)

        provider.driver.concurrentRefreshAvailabilityError = ProbeFailure()
        await session.reloadConcurrentRefreshAvailability(provider: provider)

        guard case .failed = session.concurrentRefresh else {
            Issue.record("expected .failed, got \(session.concurrentRefresh)")
            return
        }
        #expect(MaterializedViewConcurrentRefreshNote(state: session.concurrentRefresh)?.text.contains("Couldn't check") == true)
    }

    @Test("A first check that fails is reported as failed")
    func firstFailureIsReported() async {
        let session = Self.makeSession(kind: .materializedView)
        let provider = ConcurrentRefreshProvider()
        provider.driver.concurrentRefreshAvailabilityError = ProbeFailure()

        await session.reloadConcurrentRefreshAvailability(provider: provider)

        guard case .failed = session.concurrentRefresh else {
            Issue.record("expected .failed, got \(session.concurrentRefresh)")
            return
        }
    }

    @Test("An engine without concurrent refresh is loaded as nil, which shows nothing")
    func engineWithoutConcurrentRefresh() async {
        let session = Self.makeSession(kind: .materializedView)
        let provider = ConcurrentRefreshProvider()

        await session.reloadConcurrentRefreshAvailability(provider: provider)

        #expect(session.concurrentRefresh == .loaded(nil))
        #expect(MaterializedViewConcurrentRefreshNote(state: session.concurrentRefresh) == nil)
    }
}
