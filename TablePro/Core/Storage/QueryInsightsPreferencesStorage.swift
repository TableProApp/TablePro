import Foundation
import os

struct QueryInsightsPreferences: Codable, Equatable, Sendable {
    var showsAllConnections: Bool
    var sources: Set<QueryHistorySource>
    var dateRange: HistoryDateRange
    var slowestRanking: QueryInsightsSlowestRanking

    /// Four weeks rather than the drawer's All Time, because a regression is a statement about a
    /// period and comparing all of history against the nothing before it has no answer.
    static let `default` = QueryInsightsPreferences(
        showsAllConnections: false,
        sources: QueryHistorySource.userAuthored,
        dateRange: .month,
        slowestRanking: .totalTime
    )

    init(
        showsAllConnections: Bool = false,
        sources: Set<QueryHistorySource> = QueryHistorySource.userAuthored,
        dateRange: HistoryDateRange = .month,
        slowestRanking: QueryInsightsSlowestRanking = .totalTime
    ) {
        self.showsAllConnections = showsAllConnections
        self.sources = sources
        self.dateRange = dateRange
        self.slowestRanking = slowestRanking
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = QueryInsightsPreferences.default
        showsAllConnections = try container.decodeIfPresent(Bool.self, forKey: .showsAllConnections)
            ?? fallback.showsAllConnections
        let decodedSources = try container.decodeIfPresent(Set<QueryHistorySource>.self, forKey: .sources)
        sources = (decodedSources?.isEmpty == false ? decodedSources : nil) ?? fallback.sources
        dateRange = try container.decodeIfPresent(HistoryDateRange.self, forKey: .dateRange) ?? fallback.dateRange
        slowestRanking = try container.decodeIfPresent(QueryInsightsSlowestRanking.self, forKey: .slowestRanking)
            ?? fallback.slowestRanking
    }
}

enum QueryInsightsPreferencesStorage {
    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryInsightsPreferencesStorage")

    private static func key(for connectionId: UUID) -> String {
        "QueryInsights.\(connectionId.uuidString)"
    }

    static func load(for connectionId: UUID) -> QueryInsightsPreferences {
        guard let data = AppStorageEnvironment.shared.defaults.data(forKey: key(for: connectionId)) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(QueryInsightsPreferences.self, from: data)
        } catch {
            logger.error("Failed to decode query insights preferences: \(error.localizedDescription, privacy: .public)")
            return .default
        }
    }

    static func save(_ preferences: QueryInsightsPreferences, for connectionId: UUID) {
        do {
            let data = try JSONEncoder().encode(preferences)
            AppStorageEnvironment.shared.defaults.set(data, forKey: key(for: connectionId))
        } catch {
            logger.error("Failed to encode query insights preferences: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func remove(for connectionId: UUID) {
        AppStorageEnvironment.shared.defaults.removeObject(forKey: key(for: connectionId))
    }
}
