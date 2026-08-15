import Foundation

protocol QueryHistoryRecording: Sendable {
    @discardableResult
    func record(_ request: QueryHistoryRecordRequest) async -> Bool
}

protocol QueryHistoryReading: Sendable {
    func fetch(_ filter: QueryHistoryFilter, after cursor: QueryHistoryCursor?, limit: Int) async -> QueryHistoryPage
    func delete(id: UUID) async -> Bool
    func clear(matching filter: QueryHistoryFilter) async -> Bool
    func count(scope: QueryHistoryScope) async -> Int
}

extension QueryHistoryReading {
    func fetch(_ filter: QueryHistoryFilter, limit: Int) async -> QueryHistoryPage {
        await fetch(filter, after: nil, limit: limit)
    }

    func clearEverything() async -> Bool {
        await clear(matching: QueryHistoryFilter(scope: .all))
    }
}
