import Foundation
import TableProConnectionLibrary
import TableProModels

// Edit mode keeps the rows it was given, so a selection outlives a project switch, a move or a sync.
nonisolated enum ConnectionListSelection {
    static func rows(_ selection: Set<LibraryRowID>, scopedTo connectionIds: Set<UUID>) -> Set<LibraryRowID> {
        selection.filter { row in
            guard case .connection(let id, _) = row else { return false }
            return connectionIds.contains(id)
        }
    }

    // What a chooser of a connection to open offers. Read from the scope each time it is shown, so a list
    // handed over when a sheet opened never outlives a sync or a move.
    static func openable(in connections: [DatabaseConnection]) -> [DatabaseConnection] {
        connections.filter { !MacOnlyConnection.isMacOnly($0) }
    }

    // The sample is never exported.
    static func exportable(in connections: [DatabaseConnection]) -> [DatabaseConnection] {
        connections.filter(\.participatesInSync)
    }

    // The connection on screen stays offered when it sits outside the active project, so the picker
    // always has the row it shows as chosen.
    static func openable(
        in scoped: [DatabaseConnection],
        keeping currentId: UUID,
        from all: [DatabaseConnection]
    ) -> [DatabaseConnection] {
        let offered = openable(in: scoped)
        guard !offered.contains(where: { $0.id == currentId }),
              let current = all.first(where: { $0.id == currentId }) else { return offered }
        return [current] + offered
    }

    // What a sheet opened on some connections still acts on once the scope has moved under it.
    static func connectionIds(_ ids: [UUID], scopedTo connectionIds: Set<UUID>) -> [UUID] {
        ids.filter { connectionIds.contains($0) }
    }

    // A connection selected in Favorites and in Connections counts once.
    static func connectionIds(in selection: Set<LibraryRowID>, scopedTo connectionIds: Set<UUID>) -> [UUID] {
        var seen: Set<UUID> = []
        return selection.compactMap { row -> UUID? in
            guard case .connection(let id, _) = row, connectionIds.contains(id), seen.insert(id).inserted else { return nil }
            return id
        }
    }
}
