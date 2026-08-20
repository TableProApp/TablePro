//
//  QueryInsights.swift
//  TablePro
//

import Foundation

/// How the activity series buckets time. A week of hourly bars is unreadable and a year of them is
/// unusable, so the range picks the unit rather than the user.
enum QueryInsightsGranularity: Sendable, Equatable {
    case hourly
    case daily

    var component: Calendar.Component {
        switch self {
        case .hourly: return .hour
        case .daily: return .day
        }
    }
}

/// What the insights tab is asking for.
///
/// Deliberately not a `QueryHistoryFilter`: that carries an outcome filter and a search term, and
/// both are wrong here. Filtering to succeeded rows would make the failure panel report a zero
/// error rate, and a search term would silently reshape every total on the screen.
struct QueryInsightsRequest: Sendable, Equatable {
    /// Ranking every shape a heavy user has ever run would cost more to render than to read.
    static let defaultLimit = 10

    /// Below this many runs in either window a ratio is noise rather than a regression.
    static let minimumRegressionSamples = 5

    /// Ranking by average needs an average to rank. One slow one-off statement would otherwise sit
    /// at the top of the list forever, which is the same floor `pg_stat_statements` users apply by
    /// hand when they sort on `mean_exec_time`.
    static let minimumMeanRankingCalls = 3

    /// Measured against history with no real regression in it: at 1.2x, one shape in five reported
    /// a false regression and raising the sample floor barely moved it. At 1.5x nothing false
    /// survived, so the ratio, not the sample count, is what separates a regression from variance.
    static let regressionRatio = 1.5

    /// A ratio alone calls 1 ms becoming 2 ms a doubling. It is, and it does not matter, so a
    /// regression also has to have grown by an amount worth a person's attention.
    static let minimumRegressionIncrease: TimeInterval = 0.025

    /// Used when the range is unbounded, where "slower than before" has no before to point at.
    static let defaultComparisonWindow: TimeInterval = 7 * 86_400

    var scope: QueryHistoryScope
    var sources: Set<QueryHistorySource>
    var since: Date?
    var until: Date?
    var limit: Int
    var referenceDate: Date

    init(
        scope: QueryHistoryScope,
        sources: Set<QueryHistorySource> = Set(QueryHistorySource.allCases),
        since: Date? = nil,
        until: Date? = nil,
        limit: Int = QueryInsightsRequest.defaultLimit,
        referenceDate: Date = Date()
    ) {
        self.scope = scope
        self.sources = sources
        self.since = since
        self.until = until
        self.limit = limit
        self.referenceDate = referenceDate
    }

    var matchesNothing: Bool {
        if sources.isEmpty { return true }
        if let since, let until, since > until { return true }
        return false
    }

    /// An unbounded range would put every bar in one bucket at day granularity for a user who has
    /// only ever run queries today, so the span decides the unit.
    var granularity: QueryInsightsGranularity {
        guard let since else { return .daily }
        let end = until ?? referenceDate
        return end.timeIntervalSince(since) <= 48 * 3_600 ? .hourly : .daily
    }

    /// "Slower than before" compares the selected range against the range immediately preceding it,
    /// so picking Last 7 Days compares against the 7 days before that.
    var comparisonWindow: TimeInterval {
        guard let since else { return Self.defaultComparisonWindow }
        let end = until ?? referenceDate
        let span = end.timeIntervalSince(since)
        return span > 0 ? span : Self.defaultComparisonWindow
    }
}

/// How the slowest panel ranks. Total time is what `pg_stat_statements` sorts by and finds the
/// query actually costing the user time; average finds the one that is slow every time it runs.
/// Neither is the obvious reading of the word "slowest", so the panel lets the user say which.
enum QueryInsightsSlowestRanking: String, Codable, CaseIterable, Sendable, Identifiable {
    case totalTime
    case averageTime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .totalTime: return String(localized: "Total Time")
        case .averageTime: return String(localized: "Average Time")
        }
    }
}

/// One query shape, with the counters `pg_stat_statements` names: how often it ran, how long it
/// took in total, and how long a single run takes on average.
struct QueryInsightsGroup: Identifiable, Sendable, Equatable {
    let fingerprintHash: Int64
    let representativeQuery: String
    /// Derived once when the row is read, never in a view body: normalizing tokenizes the whole
    /// statement, and every row reads this several times on every pass.
    let normalizedQuery: String
    let databaseType: DatabaseType
    let callCount: Int
    let failureCount: Int
    let totalDuration: TimeInterval
    let maxDuration: TimeInterval
    let totalRows: Int
    let statementType: QueryHistoryStatementType
    let latestErrorMessage: String?

    var id: Int64 { fingerprintHash }

    var meanDuration: TimeInterval {
        callCount > 0 ? totalDuration / Double(callCount) : 0
    }

    var failureRate: Double {
        callCount > 0 ? Double(failureCount) / Double(callCount) : 0
    }
}

/// A shape whose average run time grew between two adjacent windows of equal length.
struct QueryInsightsRegression: Identifiable, Sendable, Equatable {
    let fingerprintHash: Int64
    let representativeQuery: String
    let normalizedQuery: String
    let databaseType: DatabaseType
    let recentCallCount: Int
    let priorCallCount: Int
    let recentMeanDuration: TimeInterval
    let priorMeanDuration: TimeInterval

    var id: Int64 { fingerprintHash }

    var ratio: Double {
        priorMeanDuration > 0 ? recentMeanDuration / priorMeanDuration : 0
    }

    /// Ranks by the time the slowdown actually costs, so a query that got 2x slower and runs all
    /// day outranks one that got 10x slower and runs twice.
    var addedTimeCost: TimeInterval {
        (recentMeanDuration - priorMeanDuration) * Double(recentCallCount)
    }
}

struct QueryInsightsActivityBucket: Identifiable, Sendable, Equatable {
    let date: Date
    let totalCount: Int
    let failedCount: Int

    var id: Date { date }

    var succeededCount: Int { max(0, totalCount - failedCount) }
}

struct QueryInsightsTotals: Sendable, Equatable {
    let totalCount: Int
    let failedCount: Int
    let distinctShapeCount: Int
    let totalDuration: TimeInterval
    let maxDuration: TimeInterval

    static let empty = QueryInsightsTotals(
        totalCount: 0,
        failedCount: 0,
        distinctShapeCount: 0,
        totalDuration: 0,
        maxDuration: 0
    )

    var meanDuration: TimeInterval {
        totalCount > 0 ? totalDuration / Double(totalCount) : 0
    }

    var failureRate: Double {
        totalCount > 0 ? Double(failedCount) / Double(totalCount) : 0
    }
}

struct QueryInsightsSnapshot: Sendable, Equatable {
    let totals: QueryInsightsTotals
    let mostRun: [QueryInsightsGroup]
    let slowest: [QueryInsightsGroup]
    let regressions: [QueryInsightsRegression]
    let failures: [QueryInsightsGroup]
    let activity: [QueryInsightsActivityBucket]
    let granularity: QueryInsightsGranularity

    static let empty = QueryInsightsSnapshot(
        totals: .empty,
        mostRun: [],
        slowest: [],
        regressions: [],
        failures: [],
        activity: [],
        granularity: .daily
    )

    var isEmpty: Bool { totals.totalCount == 0 }
}
