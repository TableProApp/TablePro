import Foundation

extension QueryHistoryStorage {
    // A set-aside copy holds rows of every connection and source, so only a clear of all of them reaches it.
    static func coversEveryRow(_ filter: QueryHistoryFilter) -> Bool {
        filter.scope.connectionId == nil
            && filter.sources == Set(QueryHistorySource.allCases)
            && filter.outcome == .any
            && (filter.searchText ?? "").isEmpty
            && filter.since == nil
            && filter.until == nil
            && filter.allowedConnectionIds == nil
    }
}
