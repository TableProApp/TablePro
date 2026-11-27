import Foundation

struct HistoryPanelPreferences: Codable, Equatable, Sendable {
    var isVisible: Bool
    var showsAllConnections: Bool
    var pinnedConnectionId: UUID?
    var sources: Set<QueryHistorySource>
    var dateRange: HistoryDateRange
    var outcome: QueryHistoryOutcome

    static let `default` = HistoryPanelPreferences(
        isVisible: false,
        showsAllConnections: false,
        pinnedConnectionId: nil,
        sources: QueryHistorySource.userAuthored,
        dateRange: .all,
        outcome: .any
    )

    init(
        isVisible: Bool = false,
        showsAllConnections: Bool = false,
        pinnedConnectionId: UUID? = nil,
        sources: Set<QueryHistorySource> = QueryHistorySource.userAuthored,
        dateRange: HistoryDateRange = .all,
        outcome: QueryHistoryOutcome = .any
    ) {
        self.isVisible = isVisible
        self.showsAllConnections = showsAllConnections
        self.pinnedConnectionId = pinnedConnectionId
        self.sources = sources
        self.dateRange = dateRange
        self.outcome = outcome
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = HistoryPanelPreferences.default
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? fallback.isVisible
        showsAllConnections = try container.decodeIfPresent(Bool.self, forKey: .showsAllConnections)
            ?? fallback.showsAllConnections
        pinnedConnectionId = try container.decodeIfPresent(UUID.self, forKey: .pinnedConnectionId)
        let decodedSources = try container.decodeIfPresent(Set<QueryHistorySource>.self, forKey: .sources)
        let resolvedSources = (decodedSources?.isEmpty == false ? decodedSources : nil) ?? fallback.sources
        sources = QueryHistorySource.migratingStoredSelection(resolvedSources)
        dateRange = try container.decodeIfPresent(HistoryDateRange.self, forKey: .dateRange) ?? fallback.dateRange
        outcome = try container.decodeIfPresent(QueryHistoryOutcome.self, forKey: .outcome) ?? fallback.outcome
    }
}

enum HistoryPanelPreferencesStorage {
    private static func key(for connectionId: UUID) -> JSONDefaultsKey<HistoryPanelPreferences> {
        JSONDefaultsKey("HistoryPanel.\(connectionId.uuidString)")
    }

    static func load(for connectionId: UUID) -> HistoryPanelPreferences {
        AppStorageEnvironment.shared.defaults.read(key(for: connectionId)).value ?? .default
    }

    static func save(_ preferences: HistoryPanelPreferences, for connectionId: UUID) {
        try? AppStorageEnvironment.shared.defaults.write(preferences, to: key(for: connectionId))
    }

    static func remove(for connectionId: UUID) {
        AppStorageEnvironment.shared.defaults.removeValue(for: key(for: connectionId))
    }
}
