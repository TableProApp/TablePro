import Foundation
import Observation
import TableProSQLGrammar

// What a run in one window may have changed in a connection's catalog, so every window on it reloads its lists.
@MainActor @Observable
final class CatalogChangeBoard {
    private struct Entry {
        let generation: Int
        let kinds: SQLCatalogObjectKinds
    }

    private static let keptEntries = 16

    private struct SessionTables {
        let driver: ObjectIdentifier
        var names: Set<String>
    }

    private var generations: [UUID: Int] = [:]
    @ObservationIgnored private var entries: [UUID: [Entry]] = [:]
    private var temporary: [UUID: SessionTables] = [:]
    private var movedSessions: [UUID: ObjectIdentifier] = [:]

    func generation(for connectionId: UUID) -> Int {
        generations[connectionId, default: 0]
    }

    func post(_ kinds: SQLCatalogObjectKinds, for connectionId: UUID) {
        guard !kinds.isEmpty else { return }
        let next = generation(for: connectionId) + 1
        generations[connectionId] = next
        let kept = entries[connectionId, default: []] + [Entry(generation: next, kinds: kinds)]
        entries[connectionId] = Array(kept.suffix(Self.keptEntries))
    }

    // A window further behind than the kept entries reloads every kind.
    func kinds(for connectionId: UUID, since seen: Int) -> SQLCatalogObjectKinds {
        let posted = entries[connectionId, default: []]
        guard let oldest = posted.first else { return [] }
        guard oldest.generation <= seen + 1 else { return .everything }
        return posted.filter { $0.generation > seen }.reduce([]) { $0.union($1.kinds) }
    }

    // Temporary tables belong to one session: a new driver starts with none.
    func temporaryTables(for connectionId: UUID, driver: ObjectIdentifier?) -> Set<String> {
        guard let driver, let tables = temporary[connectionId], tables.driver == driver else { return [] }
        return tables.names
    }

    func noteSessionEffect(_ effect: SessionLocalStatements.Effect, for connectionId: UUID, driver: ObjectIdentifier) {
        if effect.leavesCatalog { movedSessions[connectionId] = driver }
        guard !effect.temporaryTables.isEmpty else { return }
        let names = temporaryTables(for: connectionId, driver: driver).union(effect.temporaryTables)
        temporary[connectionId] = SessionTables(driver: driver, names: names)
    }

    // Until a database switch puts the session back on the database the window shows.
    func sessionLeftCatalog(for connectionId: UUID, driver: ObjectIdentifier?) -> Bool {
        guard let driver else { return false }
        return movedSessions[connectionId] == driver
    }

    func noteSessionDatabaseSwitched(for connectionId: UUID) {
        movedSessions[connectionId] = nil
    }
}
