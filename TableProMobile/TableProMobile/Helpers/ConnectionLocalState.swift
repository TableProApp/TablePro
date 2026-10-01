import Foundation

nonisolated struct ConnectionLocalState {
    let secrets: ConnectionSecrets
    let queryHistory: QueryHistoryStorage
    let defaults: UserDefaults

    func purge(_ connectionIds: Set<UUID>) {
        guard !connectionIds.isEmpty else { return }
        for connectionId in connectionIds {
            secrets.delete(for: connectionId)
            for key in ConnectionDefaultsKey.allCases {
                defaults.removeObject(forKey: key.name(for: connectionId))
            }
        }
        queryHistory.clearAll(for: connectionIds)
    }
}
