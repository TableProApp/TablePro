import Foundation

struct QueryHistoryInsight: Hashable, Identifiable {
    struct ID: Hashable {
        let connectionId: UUID
        let databaseName: String
        let query: String
    }

    let connectionId: UUID
    let databaseName: String
    let query: String
    let executionCount: Int
    let successfulExecutionCount: Int
    let averageExecutionTime: TimeInterval
    let maximumExecutionTime: TimeInterval
    let lastExecutedAt: Date
    let recentExecutionCount: Int
    let recentAverageExecutionTime: TimeInterval
    let previousExecutionCount: Int
    let previousAverageExecutionTime: TimeInterval

    var id: ID {
        ID(connectionId: connectionId, databaseName: databaseName, query: query)
    }

    var slowdownRatio: Double {
        guard previousAverageExecutionTime > 0,
              previousAverageExecutionTime.isFinite,
              recentAverageExecutionTime >= 0,
              recentAverageExecutionTime.isFinite
        else {
            return 0
        }
        let ratio = recentAverageExecutionTime / previousAverageExecutionTime
        return ratio.isFinite ? ratio : .greatestFiniteMagnitude
    }

    var slowdownPercentage: Int {
        let percentage = (slowdownRatio - 1) * 100
        guard percentage > 0 else { return 0 }
        guard percentage.isFinite else { return Int(Int32.max) }
        return Int(min(percentage.rounded(), Double(Int32.max)))
    }
}

struct QueryHistoryInsightSnapshot: Equatable {
    static let empty = QueryHistoryInsightSnapshot(mostRun: [], slowest: [], regressions: [])

    let mostRun: [QueryHistoryInsight]
    let slowest: [QueryHistoryInsight]
    let regressions: [QueryHistoryInsight]

    var isEmpty: Bool {
        mostRun.isEmpty && slowest.isEmpty && regressions.isEmpty
    }

    func insights(in category: QueryHistoryInsightCategory) -> [QueryHistoryInsight] {
        switch category {
        case .mostRun:
            return mostRun
        case .slowest:
            return slowest
        case .regression:
            return regressions
        }
    }

    func insight(for selection: QueryHistoryInsightSelection) -> QueryHistoryInsight? {
        insights(in: selection.category).first { $0.id == selection.insightId }
    }
}

enum QueryHistoryInsightCategory: Hashable {
    case mostRun
    case slowest
    case regression
}

struct QueryHistoryInsightSelection: Hashable {
    let category: QueryHistoryInsightCategory
    let insightId: QueryHistoryInsight.ID

    init(category: QueryHistoryInsightCategory, insightId: QueryHistoryInsight.ID) {
        self.category = category
        self.insightId = insightId
    }

    init(category: QueryHistoryInsightCategory, insight: QueryHistoryInsight) {
        self.init(category: category, insightId: insight.id)
    }
}

enum QueryHistoryInsightPolicy {
    static let comparisonWindow: TimeInterval = 7 * 24 * 60 * 60
    static let minimumRegressionSamples = 3
    static let minimumSlowdownRatio = 1.25
    static let minimumSlowdownDuration: TimeInterval = 0.05
    static let maximumResultLimit = 50
}
