import Foundation

@MainActor
final class ClosedTabDraftStorage {
    static let shared = ClosedTabDraftStorage()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func draftKey(connectionId: UUID) -> String {
        "com.TablePro.closedTabDraft.\(connectionId.uuidString)"
    }

    func saveQuery(_ query: String, connectionId: UUID) {
        defaults.set(cappedQuery(query), forKey: draftKey(connectionId: connectionId))
    }

    func consumeQuery(connectionId: UUID) -> String? {
        let key = draftKey(connectionId: connectionId)
        guard let query = defaults.string(forKey: key), !query.isEmpty else { return nil }
        defaults.removeObject(forKey: key)
        return query
    }

    func removeDraft(for connectionId: UUID) {
        defaults.removeObject(forKey: draftKey(connectionId: connectionId))
    }

    func removeDrafts(for connectionIds: Set<UUID>) {
        for id in connectionIds { removeDraft(for: id) }
    }

    static func draftCandidate(from tabs: [QueryTab], selectedTabId: UUID?) -> String? {
        let candidates = tabs.filter { tab in
            tab.tabType == .query
                && tab.content.sourceFileURL == nil
                && !tab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let selectedTabId,
           let selected = candidates.first(where: { $0.id == selectedTabId }) {
            return selected.content.query
        }
        return candidates.first?.content.query
    }

    private func cappedQuery(_ query: String) -> String {
        let queryNS = query as NSString
        guard queryNS.length > TabQueryContent.maxPersistableQuerySize else { return query }
        return queryNS.substring(to: TabQueryContent.maxPersistableQuerySize)
    }
}
