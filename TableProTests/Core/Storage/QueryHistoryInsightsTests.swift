import Foundation
@testable import TablePro
import Testing

@Suite("QueryHistoryInsights")
struct QueryHistoryInsightsTests {
    @Test("Empty history returns an empty snapshot")
    func emptyHistoryReturnsEmptySnapshot() async {
        let snapshot = await storage.fetchInsights(connectionId: connectionId, referenceDate: referenceDate)
        #expect(snapshot == .empty)
    }

    @Test("Frequency includes failures while latency uses successful runs")
    func frequencyAndLatencyUseCorrectPopulations() async throws {
        await add(query: "SELECT popular", offset: -100, duration: 0.2)
        await add(query: "SELECT popular", offset: -90, duration: 0.4)
        await add(query: "SELECT popular", offset: -80, duration: 20, successful: false)
        await add(query: "SELECT slower", offset: -70, duration: 1.2)

        let snapshot = await storage.fetchInsights(connectionId: connectionId, referenceDate: referenceDate)
        let popular = try #require(snapshot.mostRun.first { $0.query == "SELECT popular" })
        let slower = try #require(snapshot.slowest.first)

        #expect(popular.executionCount == 3)
        #expect(popular.successfulExecutionCount == 2)
        #expect(abs(popular.averageExecutionTime - 0.3) < 0.000_001)
        #expect(popular.maximumExecutionTime == 0.4)
        #expect(slower.query == "SELECT slower")
        #expect(slower.averageExecutionTime == 1.2)
    }

    @Test("Insights stay within one connection and one database")
    func connectionAndDatabaseScopesStaySeparate() async {
        let otherConnectionId = UUID()
        await add(query: "SELECT scoped", databaseName: "primary", offset: -100, duration: 0.2)
        await add(query: "SELECT scoped", databaseName: "analytics", offset: -90, duration: 0.3)
        await add(
            query: "SELECT scoped",
            databaseName: "primary",
            offset: -80,
            duration: 10,
            connectionId: otherConnectionId
        )

        let snapshot = await storage.fetchInsights(connectionId: connectionId, referenceDate: referenceDate)
        let scoped = snapshot.mostRun.filter { $0.query == "SELECT scoped" }

        #expect(scoped.count == 2)
        #expect(Set(scoped.map(\.databaseName)) == ["primary", "analytics"])
        #expect(scoped.allSatisfy { $0.connectionId == connectionId && $0.executionCount == 1 })
    }

    @Test("Regression requires both sample windows and meaningful slowdown")
    func regressionPolicyFiltersNoise() async throws {
        for offset in [-1_000_000.0, -950_000, -900_000] {
            await add(query: "SELECT regressed", offset: offset, duration: 0.2)
            await add(query: "SELECT small_delta", offset: offset, duration: 0.1)
            await add(query: "SELECT small_ratio", offset: offset, duration: 1.0)
        }
        for offset in [-300_000.0, -200_000, -100_000] {
            await add(query: "SELECT regressed", offset: offset, duration: 0.4)
            await add(query: "SELECT small_delta", offset: offset, duration: 0.13)
            await add(query: "SELECT small_ratio", offset: offset, duration: 1.2)
        }
        for offset in [-1_000_000.0, -900_000] {
            await add(query: "SELECT undersampled", offset: offset, duration: 0.1)
        }
        for offset in [-300_000.0, -100_000] {
            await add(query: "SELECT undersampled", offset: offset, duration: 1.0)
        }
        await add(query: "SELECT regressed", offset: -50_000, duration: 100, successful: false)

        let snapshot = await storage.fetchInsights(connectionId: connectionId, referenceDate: referenceDate)
        let regression = try #require(snapshot.regressions.first)

        #expect(snapshot.regressions.count == 1)
        #expect(regression.query == "SELECT regressed")
        #expect(regression.recentExecutionCount == 3)
        #expect(regression.previousExecutionCount == 3)
        #expect(regression.slowdownPercentage == 100)
    }

    @Test("Comparison windows are half open and future entries are excluded")
    func comparisonBoundariesAreStable() async throws {
        let window = QueryHistoryInsightPolicy.comparisonWindow
        await add(query: "SELECT boundary", offset: -(2 * window), duration: 0.2)
        await add(query: "SELECT boundary", offset: -window, duration: 0.4)
        await add(query: "SELECT boundary", offset: -1, duration: 0.4)
        await add(query: "SELECT boundary", offset: 0, duration: 50)
        await add(query: "SELECT boundary", offset: 1, duration: 50)

        let snapshot = await storage.fetchInsights(connectionId: connectionId, referenceDate: referenceDate)
        let boundary = try #require(snapshot.mostRun.first { $0.query == "SELECT boundary" })

        #expect(boundary.executionCount == 3)
        #expect(boundary.previousExecutionCount == 1)
        #expect(boundary.recentExecutionCount == 2)
    }

    @Test("Blank queries and invalid durations do not create latency insights")
    func unusableRowsStayOutOfLatencyInsights() async {
        await add(query: "   \n", offset: -10, duration: 10)
        await add(query: "SELECT negative", offset: -9, duration: -1)
        await add(query: "SELECT infinite", offset: -8, duration: .infinity)
        await add(query: "SELECT valid", offset: -8, duration: 0.2)

        let snapshot = await storage.fetchInsights(connectionId: connectionId, referenceDate: referenceDate)

        #expect(snapshot.mostRun.contains { $0.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == false)
        #expect(snapshot.mostRun.contains { $0.query == "SELECT negative" })
        #expect(snapshot.slowest.contains { $0.query == "SELECT negative" } == false)
        #expect(snapshot.mostRun.contains { $0.query == "SELECT infinite" })
        #expect(snapshot.slowest.contains { $0.query == "SELECT infinite" } == false)
        #expect(snapshot.slowest.map(\.query) == ["SELECT valid"])
    }

    @Test("Bound parameters keep query text from changing the history schema")
    func queryTextCannotChangeHistorySchema() async {
        let hostileQuery = "SELECT 'x'); DROP TABLE history; --"
        await add(query: hostileQuery, offset: -10, duration: 0.1)

        let firstSnapshot = await storage.fetchInsights(connectionId: connectionId, referenceDate: referenceDate)
        await add(query: "SELECT still_here", offset: -5, duration: 0.2)
        let entries = await storage.fetchHistory(connectionId: connectionId)

        #expect(firstSnapshot.mostRun.contains { $0.query == hostileQuery })
        #expect(entries.count == 2)
    }

    @Test("Limits reject nonpositive values and cap oversized requests")
    func resultLimitIsBounded() async {
        for index in 0..<55 {
            await add(query: "SELECT limit_\(index)", offset: -Double(index + 1), duration: Double(index + 1))
        }

        let rejected = await storage.fetchInsights(
            connectionId: connectionId,
            referenceDate: referenceDate,
            limit: -1
        )
        let capped = await storage.fetchInsights(
            connectionId: connectionId,
            referenceDate: referenceDate,
            limit: .max
        )

        #expect(rejected == .empty)
        #expect(capped.mostRun.count == QueryHistoryInsightPolicy.maximumResultLimit)
        #expect(capped.slowest.count == QueryHistoryInsightPolicy.maximumResultLimit)
    }

    @Test("An invalid reference date returns no insights")
    func invalidReferenceDateReturnsEmptySnapshot() async {
        let snapshot = await storage.fetchInsights(
            connectionId: connectionId,
            referenceDate: Date(timeIntervalSince1970: .infinity)
        )
        #expect(snapshot == .empty)
    }

    @Test("Extreme latency ratios stay representable")
    func extremeLatencyRatioStaysRepresentable() {
        let insight = QueryHistoryInsight(
            connectionId: connectionId,
            databaseName: "analytics",
            query: "SELECT extreme",
            executionCount: 6,
            successfulExecutionCount: 6,
            averageExecutionTime: 1,
            maximumExecutionTime: 1,
            lastExecutedAt: referenceDate,
            recentExecutionCount: 3,
            recentAverageExecutionTime: .greatestFiniteMagnitude,
            previousExecutionCount: 3,
            previousAverageExecutionTime: .leastNonzeroMagnitude
        )

        #expect(insight.slowdownRatio == .greatestFiniteMagnitude)
        #expect(insight.slowdownPercentage == Int(Int32.max))
    }

    private let storage = QueryHistoryStorageTests.makeIsolatedStorage()
    private let connectionId = UUID()
    private let referenceDate = Date(timeIntervalSince1970: 2_000_000_000)

    private func add(
        query: String,
        databaseName: String = "analytics",
        offset: TimeInterval,
        duration: TimeInterval,
        successful: Bool = true,
        connectionId: UUID? = nil
    ) async {
        let entry = QueryHistoryEntry(
            query: query,
            connectionId: connectionId ?? self.connectionId,
            databaseName: databaseName,
            executedAt: referenceDate.addingTimeInterval(offset),
            executionTime: duration,
            rowCount: 1,
            wasSuccessful: successful,
            errorMessage: successful ? nil : "failed"
        )
        #expect(await storage.addHistory(entry))
    }
}
