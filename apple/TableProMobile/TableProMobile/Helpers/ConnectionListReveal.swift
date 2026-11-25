import Foundation
import TableProConnectionLibrary
import TableProModels

// Outside edit mode a tap opens the row, so the list has no mark to set there and the reveal and scroll stand in for it.
nonisolated struct ConnectionListReveal: Equatable, Sendable {
    let clearsQuery: Bool
    let groupIdsToExpand: Set<UUID>
    let scrollTarget: LibraryRowID
    let selection: Set<LibraryRowID>?

    static func plan(
        revealing connectionIds: [UUID],
        in request: LibraryOutlineRequest<DatabaseConnection, ConnectionGroup, ConnectionTag>,
        collapsedGroupIds: Set<UUID>,
        isEditing: Bool
    ) -> ConnectionListReveal? {
        let connectionsById = Dictionary(request.connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let revealed = Set(connectionIds.filter { connectionsById[$0] != nil })
        guard !revealed.isEmpty else { return nil }

        let current = LibraryOutlineBuilder.build(request)
        let clearsQuery = request.query.isActive && !revealed.isSubset(of: current.connectionIds(in: .connections))
        var cleared = request
        cleared.query = LibraryQuery()
        let outline = clearsQuery ? LibraryOutlineBuilder.build(cleared) : current
        guard let first = outline.connectionIds(in: .connections).first(where: revealed.contains) else { return nil }

        let graph = LibraryGroupGraph(groups: request.groups)
        let ancestors = revealed.compactMap { connectionsById[$0]?.groupId }.flatMap { graph.pathIds(to: $0) }
        return ConnectionListReveal(
            clearsQuery: clearsQuery,
            groupIdsToExpand: collapsedGroupIds.intersection(ancestors),
            scrollTarget: .connection(first, section: .connections),
            selection: isEditing ? Set(revealed.map { LibraryRowID.connection($0, section: .connections) }) : nil
        )
    }
}
