import Foundation
import os

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
    private static let logger = Logger(subsystem: "com.TablePro", category: "HistoryPanelPreferencesStorage")

    private static func key(for connectionId: UUID) -> String {
        "HistoryPanel.\(connectionId.uuidString)"
    }

    static func load(for connectionId: UUID) -> HistoryPanelPreferences {
        guard let data = AppStorageEnvironment.shared.defaults.data(forKey: key(for: connectionId)) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(HistoryPanelPreferences.self, from: data)
        } catch {
            logger.error("Failed to decode history panel preferences: \(error.localizedDescription, privacy: .public)")
            return .default
        }
    }

    static func save(_ preferences: HistoryPanelPreferences, for connectionId: UUID) {
        do {
            let data = try JSONEncoder().encode(preferences)
            AppStorageEnvironment.shared.defaults.set(data, forKey: key(for: connectionId))
        } catch {
            logger.error("Failed to encode history panel preferences: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func remove(for connectionId: UUID) {
        AppStorageEnvironment.shared.defaults.removeObject(forKey: key(for: connectionId))
    }
}
