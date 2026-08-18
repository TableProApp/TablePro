//
//  QueryHistoryInsightsTests.swift
//  TableProTests
//
//  Aggregate queries over the query history store.
//  Uses unique connectionIds and an isolated database file per test.
//

import Foundation
@testable import TablePro
import Testing

@Suite("QueryHistoryInsights")
struct QueryHistoryInsightsTests {
    private let storage: QueryHistoryStorage
    private let connectionId = UUID()

    init() {
        self.storage = QueryHistoryStorage(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tablepro-tests")
                .appendingPathComponent("query_insights_\(UUID().uuidString).db"),
            removeDatabaseOnDeinit: true
        )
    }

    private func record(
        _ query: String,
        executedAt: Date = Date(),
        executionTime: TimeInterval = 0.05,
        rowCount: Int = 10,
        wasSuccessful: Bool = true,
        errorMessage: String? = nil,
        source: QueryHistorySource = .editor,
        databaseType: DatabaseType = .postgresql
    ) async {
        _ = await storage.record(QueryHistoryEntry(
            query: query,
            connectionId: connectionId,
            databaseName: "testdb",
            databaseType: databaseType,
            source: source,
            executedAt: executedAt,
            executionTime: executionTime,
            rowCount: rowCount,
            wasSuccessful: wasSuccessful,
            errorMessage: errorMessage
        ))
    }

    private func insights(
        since: Date? = nil,
        ranking: QueryInsightsSlowestRanking = .totalTime,
        referenceDate: Date = Date()
    ) async -> QueryInsightsSnapshot {
        await storage.insights(
            QueryInsightsRequest(
                scope: .connection(connectionId),
                since: since,
                referenceDate: referenceDate
            ),
            slowestRanking: ranking
        )
    }

    // MARK: - Grouping

    @Test("Queries differing only by literal values count as one shape")
    func literalsGroupTogether() async {
        for id in 1...5 {
            await record("SELECT * FROM users WHERE id = \(id)")
        }
        let snapshot = await insights()

        #expect(snapshot.totals.totalCount == 5)
        #expect(snapshot.totals.distinctShapeCount == 1)
        #expect(snapshot.mostRun.count == 1)
        #expect(snapshot.mostRun.first?.callCount == 5)
        #expect(snapshot.mostRun.first?.normalizedQuery == "SELECT * FROM users WHERE id = ?")
    }

    @Test("Different queries stay in different groups")
    func differentQueriesStaySeparate() async {
        await record("SELECT * FROM users WHERE id = 1")
        await record("SELECT * FROM orders WHERE id = 1")
        let snapshot = await insights()

        #expect(snapshot.totals.distinctShapeCount == 2)
        #expect(snapshot.mostRun.count == 2)
    }

    @Test("Most run ranks by how often a shape ran")
    func mostRunIsOrderedByCallCount() async {
        for _ in 0..<2 { await record("SELECT * FROM rare WHERE id = 1") }
        for _ in 0..<9 { await record("SELECT * FROM common WHERE id = 1") }
        let snapshot = await insights()

        #expect(snapshot.mostRun.first?.callCount == 9)
        #expect(snapshot.mostRun.first?.normalizedQuery.contains("common") == true)
    }

    // MARK: - Slowest

    @Test("Slowest ranks by total time, so a frequent query outranks one slow run")
    func slowestRanksByTotalTime() async {
        await record("SELECT * FROM oneoff WHERE id = 1", executionTime: 2.0)
        for _ in 0..<20 { await record("SELECT * FROM frequent WHERE id = 1", executionTime: 0.5) }

        let snapshot = await insights(ranking: .totalTime)
        #expect(snapshot.slowest.first?.normalizedQuery.contains("frequent") == true)
        #expect(snapshot.slowest.first?.totalDuration == 10.0)
    }

    @Test("Ranking by average needs a minimum run count, so one slow one-off cannot top it")
    func averageRankingAppliesCallFloor() async {
        await record("SELECT * FROM oneoff WHERE id = 1", executionTime: 9.0)
        for _ in 0..<5 { await record("SELECT * FROM frequent WHERE id = 1", executionTime: 0.5) }

        let snapshot = await insights(ranking: .averageTime)
        let names = snapshot.slowest.map(\.normalizedQuery)
        #expect(names.allSatisfy { !$0.contains("oneoff") })
        #expect(snapshot.slowest.first?.normalizedQuery.contains("frequent") == true)
    }

    // MARK: - Totals

    @Test("Totals count failures separately from runs")
    func totalsCountFailures() async {
        for _ in 0..<8 { await record("SELECT 1", executionTime: 0.1) }
        for _ in 0..<2 { await record("SELECT bad", wasSuccessful: false, errorMessage: "boom") }

        let snapshot = await insights()
        #expect(snapshot.totals.totalCount == 10)
        #expect(snapshot.totals.failedCount == 2)
        #expect(snapshot.totals.failureRate == 0.2)
    }

    @Test("An unknown row count never inflates the row total")
    func unknownRowCountIsNotSummed() async {
        await record("CREATE TABLE t (id INT)", rowCount: -1)
        await record("SELECT * FROM t WHERE id = 1", rowCount: 40)

        let snapshot = await insights()
        let rows = snapshot.mostRun.reduce(0) { $0 + $1.totalRows }
        #expect(rows == 40)
    }

    // MARK: - Failures

    @Test("The failures panel only holds shapes that actually failed")
    func failuresPanelExcludesHealthyQueries() async {
        for _ in 0..<5 { await record("SELECT 1") }
        for _ in 0..<3 {
            await record("SELECT * FROM missing WHERE id = 1", wasSuccessful: false, errorMessage: "no such table")
        }

        let snapshot = await insights()
        #expect(snapshot.failures.count == 1)
        #expect(snapshot.failures.first?.failureCount == 3)
        #expect(snapshot.failures.first?.latestErrorMessage == "no such table")
    }

    @Test("The error shown is one from inside the range, not an older one the filter excludes")
    func failureMessageRespectsTheDateRange() async {
        let now = Date()
        await record(
            "SELECT * FROM t WHERE id = 1",
            executedAt: now.addingTimeInterval(-40 * 86_400),
            wasSuccessful: false,
            errorMessage: "ancient failure"
        )
        await record(
            "SELECT * FROM t WHERE id = 2",
            executedAt: now,
            wasSuccessful: false,
            errorMessage: "todays failure"
        )

        let snapshot = await insights(since: now.addingTimeInterval(-86_400), referenceDate: now)
        #expect(snapshot.failures.first?.failureCount == 1)
        #expect(snapshot.failures.first?.latestErrorMessage == "todays failure")
    }

    // MARK: - Regressions

    @Test("A query that got materially slower is reported")
    func regressionIsDetected() async {
        let now = Date()
        let day: TimeInterval = 86_400
        for index in 0..<6 {
            await record(
                "SELECT * FROM slow WHERE id = 1",
                executedAt: now.addingTimeInterval(-10 * day + Double(index) * 3_600),
                executionTime: 0.05
            )
        }
        for index in 0..<6 {
            await record(
                "SELECT * FROM slow WHERE id = 1",
                executedAt: now.addingTimeInterval(-2 * day + Double(index) * 3_600),
                executionTime: 0.40
            )
        }

        let snapshot = await insights(since: now.addingTimeInterval(-7 * day), referenceDate: now)
        #expect(snapshot.regressions.count == 1)
        let regression = snapshot.regressions.first
        #expect(regression?.recentCallCount == 6)
        #expect(regression?.priorCallCount == 6)
        #expect((regression?.ratio ?? 0) > 5)
    }

    @Test("Noise below the ratio threshold is not called a regression")
    func smallVariationIsNotARegression() async {
        let now = Date()
        let day: TimeInterval = 86_400
        for index in 0..<8 {
            await record(
                "SELECT * FROM steady WHERE id = 1",
                executedAt: now.addingTimeInterval(-10 * day + Double(index) * 3_600),
                executionTime: 0.20
            )
        }
        for index in 0..<8 {
            await record(
                "SELECT * FROM steady WHERE id = 1",
                executedAt: now.addingTimeInterval(-2 * day + Double(index) * 3_600),
                executionTime: 0.24
            )
        }

        let snapshot = await insights(since: now.addingTimeInterval(-7 * day), referenceDate: now)
        #expect(snapshot.regressions.isEmpty)
    }

    @Test("A large ratio on a trivial duration is not worth reporting")
    func absoluteIncreaseFloorApplies() async {
        let now = Date()
        let day: TimeInterval = 86_400
        for index in 0..<8 {
            await record(
                "SELECT * FROM tiny WHERE id = 1",
                executedAt: now.addingTimeInterval(-10 * day + Double(index) * 3_600),
                executionTime: 0.001
            )
        }
        for index in 0..<8 {
            await record(
                "SELECT * FROM tiny WHERE id = 1",
                executedAt: now.addingTimeInterval(-2 * day + Double(index) * 3_600),
                executionTime: 0.006
            )
        }

        let snapshot = await insights(since: now.addingTimeInterval(-7 * day), referenceDate: now)
        #expect(snapshot.regressions.isEmpty)
    }

    @Test("Too few runs to compare is not a regression")
    func sampleFloorApplies() async {
        let now = Date()
        let day: TimeInterval = 86_400
        await record("SELECT * FROM rare WHERE id = 1", executedAt: now.addingTimeInterval(-10 * day), executionTime: 0.01)
        await record("SELECT * FROM rare WHERE id = 1", executedAt: now.addingTimeInterval(-2 * day), executionTime: 2.0)

        let snapshot = await insights(since: now.addingTimeInterval(-7 * day), referenceDate: now)
        #expect(snapshot.regressions.isEmpty)
    }

    @Test("A failed run never counts toward a duration comparison")
    func regressionsIgnoreFailures() async {
        let now = Date()
        let day: TimeInterval = 86_400
        for index in 0..<6 {
            await record(
                "SELECT * FROM t WHERE id = 1",
                executedAt: now.addingTimeInterval(-10 * day + Double(index) * 3_600),
                executionTime: 0.30
            )
        }
        for index in 0..<6 {
            await record(
                "SELECT * FROM t WHERE id = 1",
                executedAt: now.addingTimeInterval(-2 * day + Double(index) * 3_600),
                executionTime: 0.001,
                wasSuccessful: false,
                errorMessage: "failed fast"
            )
        }

        let snapshot = await insights(since: now.addingTimeInterval(-7 * day), referenceDate: now)
        #expect(snapshot.regressions.isEmpty)
    }

    // MARK: - Filtering

    @Test("A source the user turned off is not counted")
    func sourceFilterApplies() async {
        for _ in 0..<4 { await record("SELECT 1", source: .editor) }
        for _ in 0..<6 { await record("SELECT 2", source: .tableBrowse) }

        let snapshot = await storage.insights(
            QueryInsightsRequest(scope: .connection(connectionId), sources: [.editor]),
            slowestRanking: .totalTime
        )
        #expect(snapshot.totals.totalCount == 4)
    }

    @Test("Another connection's queries stay out of a scoped request")
    func scopeFilterApplies() async {
        for _ in 0..<3 { await record("SELECT 1") }
        _ = await storage.record(QueryHistoryEntry(
            query: "SELECT 2",
            connectionId: UUID(),
            databaseName: "other",
            databaseType: .mysql,
            source: .editor,
            executionTime: 0.1,
            rowCount: 1,
            wasSuccessful: true
        ))

        let scoped = await insights()
        #expect(scoped.totals.totalCount == 3)

        let everything = await storage.insights(
            QueryInsightsRequest(scope: .all),
            slowestRanking: .totalTime
        )
        #expect(everything.totals.totalCount == 4)
    }

    @Test("A date range excludes what falls outside it")
    func dateRangeApplies() async {
        let now = Date()
        await record("SELECT 1", executedAt: now.addingTimeInterval(-40 * 86_400))
        await record("SELECT 2", executedAt: now)

        let snapshot = await insights(since: now.addingTimeInterval(-7 * 86_400), referenceDate: now)
        #expect(snapshot.totals.totalCount == 1)
    }

    // MARK: - Activity

    @Test("Activity buckets separate failures from successes")
    func activitySplitsOutcomes() async {
        let now = Date()
        for _ in 0..<3 { await record("SELECT 1", executedAt: now) }
        await record("SELECT bad", executedAt: now, wasSuccessful: false, errorMessage: "boom")

        let snapshot = await insights(since: now.addingTimeInterval(-7 * 86_400), referenceDate: now)
        let total = snapshot.activity.reduce(0) { $0 + $1.totalCount }
        let failed = snapshot.activity.reduce(0) { $0 + $1.failedCount }
        #expect(total == 4)
        #expect(failed == 1)
    }

    @Test("A short range buckets by hour and a long one by day")
    func granularityFollowsRange() async {
        let now = Date()
        await record("SELECT 1", executedAt: now)

        let short = await insights(since: now.addingTimeInterval(-3_600), referenceDate: now)
        #expect(short.granularity == .hourly)

        let long = await insights(since: now.addingTimeInterval(-28 * 86_400), referenceDate: now)
        #expect(long.granularity == .daily)
    }

    // MARK: - Empty and degenerate input

    @Test("An empty store reports empty rather than failing")
    func emptyStoreIsEmpty() async {
        let snapshot = await insights()
        #expect(snapshot.isEmpty)
        #expect(snapshot.totals.totalCount == 0)
        #expect(snapshot.mostRun.isEmpty)
    }

    @Test("A request that can match nothing does no work")
    func impossibleRequestReturnsEmpty() async {
        await record("SELECT 1")
        let snapshot = await storage.insights(
            QueryInsightsRequest(scope: .connection(connectionId), sources: []),
            slowestRanking: .totalTime
        )
        #expect(snapshot.isEmpty)
    }

    @Test("Every recorded row gets a fingerprint, so nothing lands in a phantom group")
    func everyRowIsFingerprinted() async {
        await record("SELECT * FROM a WHERE id = 1")
        await record("SELECT * FROM b WHERE id = 2")
        await record("CREATE TABLE c (id INT)", rowCount: -1)

        let snapshot = await insights()
        let grouped = snapshot.mostRun.reduce(0) { $0 + $1.callCount }
        #expect(grouped == snapshot.totals.totalCount)
        #expect(snapshot.totals.distinctShapeCount == 3)
    }
}
