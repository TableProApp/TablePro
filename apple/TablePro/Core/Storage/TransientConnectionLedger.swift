//
//  TransientConnectionLedger.swift
//  TablePro
//

import Foundation

/// Connections this Mac opened without saving them: a database file, a link. Each such open makes a
/// new id, and once its window closes nothing can reach that id again, so the view state written
/// under it would stay in the defaults domain for good. The next launch removes it.
@MainActor
internal struct TransientConnectionLedger {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppStorageEnvironment.shared.defaults) {
        self.defaults = defaults
    }

    var ids: Set<UUID> {
        guard case .value(let ids) = defaults.read(PreferenceKeys.transientConnectionIds) else { return [] }
        return Set(ids)
    }

    /// A library that failed to load lists no connection, so every saved one would look transient, and
    /// the next launch would delete its tiles, MCP settings and view state. Nothing is recorded then.
    static func isTransient(
        _ connection: DatabaseConnection,
        libraryLoaded: Bool,
        savedIds: Set<UUID>,
        unreadableIds: Set<UUID>
    ) -> Bool {
        guard libraryLoaded else { return false }
        switch connection.origin {
        case .linkedFolder, .teamLibrary:
            return false
        case .thisMac, .imported, .synced, .link:
            return !savedIds.contains(connection.id) && !unreadableIds.contains(connection.id)
        }
    }

    func recordIfTransient(_ connection: DatabaseConnection, library: ConnectionStorage) {
        let saved = library.loadConnections()
        guard Self.isTransient(
            connection,
            libraryLoaded: !library.lastLoadFailed,
            savedIds: Set(saved.map(\.id)),
            unreadableIds: library.unreadableConnectionIds
        ) else { return }
        var recorded = ids
        guard recorded.insert(connection.id).inserted else { return }
        write(recorded)
    }

    /// Purges the ids no window can reach any more: recorded, not saved since, not unreadable, and
    /// with no session open. An id saved after it was recorded leaves the ledger and keeps its state.
    /// A library that fails to load keeps the ledger for the next launch. An id leaves only after its
    /// purge ran, so a quit in between tries again.
    func purgeUnreachable(
        library: ConnectionStorage,
        openSessionIds: Set<UUID>,
        purge: (Set<UUID>) -> Void
    ) {
        let recorded = ids
        guard !recorded.isEmpty else { return }
        let saved = Set(library.loadConnections().map(\.id))
        guard !library.lastLoadFailed else { return }
        let unreadable = library.unreadableConnectionIds

        let nowSaved = recorded.filter { saved.contains($0) || unreadable.contains($0) }
        let unreachable = recorded.subtracting(nowSaved).subtracting(openSessionIds)
        purge(unreachable)
        write(recorded.subtracting(nowSaved).subtracting(unreachable))
    }

    private func write(_ recorded: Set<UUID>) {
        guard !recorded.isEmpty else {
            defaults.removeValue(for: PreferenceKeys.transientConnectionIds)
            return
        }
        try? defaults.write(recorded.sorted { $0.uuidString < $1.uuidString }, to: PreferenceKeys.transientConnectionIds)
    }
}
