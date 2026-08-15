import Foundation

enum QueryHistoryScope: Sendable, Equatable, Codable {
    case connection(UUID)
    case all

    var connectionId: UUID? {
        switch self {
        case .connection(let id): return id
        case .all: return nil
        }
    }
}

enum QueryHistoryOutcome: String, Sendable, Codable, CaseIterable {
    case any
    case succeeded
    case failed

    var displayName: String {
        switch self {
        case .any: return String(localized: "Any Outcome")
        case .succeeded: return String(localized: "Succeeded")
        case .failed: return String(localized: "Failed")
        }
    }
}

struct QueryHistoryFilter: Sendable, Equatable {
    var scope: QueryHistoryScope
    var sources: Set<QueryHistorySource>
    var outcome: QueryHistoryOutcome
    var searchText: String?
    var since: Date?
    var until: Date?
    var allowedConnectionIds: Set<UUID>?

    init(
        scope: QueryHistoryScope,
        sources: Set<QueryHistorySource> = Set(QueryHistorySource.allCases),
        outcome: QueryHistoryOutcome = .any,
        searchText: String? = nil,
        since: Date? = nil,
        until: Date? = nil,
        allowedConnectionIds: Set<UUID>? = nil
    ) {
        self.scope = scope
        self.sources = sources
        self.outcome = outcome
        self.searchText = searchText
        self.since = since
        self.until = until
        self.allowedConnectionIds = allowedConnectionIds
    }

    var matchesNothing: Bool {
        if sources.isEmpty { return true }
        if let allowedConnectionIds, allowedConnectionIds.isEmpty { return true }
        if let since, let until, since > until { return true }
        return false
    }
}

struct QueryHistoryCursor: Sendable, Equatable {
    let executedAt: Date
    let id: UUID
}

struct QueryHistoryPage: Sendable {
    let entries: [QueryHistoryEntry]
    let nextCursor: QueryHistoryCursor?

    static let empty = QueryHistoryPage(entries: [], nextCursor: nil)
}
