import Foundation

struct QueryInsightsPreferences: Codable, Equatable, Sendable {
    var showsAllConnections: Bool
    var sources: Set<QueryHistorySource>
    var dateRange: HistoryDateRange
    var slowestRanking: QueryInsightsSlowestRanking

    // Four weeks, not the drawer's All Time: a regression compares a period with the one before it.
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
        let resolvedSources = (decodedSources?.isEmpty == false ? decodedSources : nil) ?? fallback.sources
        sources = QueryHistorySource.migratingStoredSelection(resolvedSources)
        dateRange = try container.decodeIfPresent(HistoryDateRange.self, forKey: .dateRange) ?? fallback.dateRange
        slowestRanking = try container.decodeIfPresent(QueryInsightsSlowestRanking.self, forKey: .slowestRanking)
            ?? fallback.slowestRanking
    }
}

enum QueryInsightsPreferencesStorage {
    private static func key(for connectionId: UUID) -> JSONDefaultsKey<QueryInsightsPreferences> {
        JSONDefaultsKey("QueryInsights.\(connectionId.uuidString)")
    }

    static func load(for connectionId: UUID) -> QueryInsightsPreferences {
        AppStorageEnvironment.shared.defaults.read(key(for: connectionId)).value ?? .default
    }

    static func save(_ preferences: QueryInsightsPreferences, for connectionId: UUID) {
        try? AppStorageEnvironment.shared.defaults.write(preferences, to: key(for: connectionId))
    }

    static func remove(for connectionId: UUID) {
        AppStorageEnvironment.shared.defaults.removeValue(for: key(for: connectionId))
    }
}
