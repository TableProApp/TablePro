import AppKit
import TableProConnectionLibrary

extension WelcomeViewModel {
    func rowModel(for row: LibraryRowID) -> WelcomeRowModel {
        switch row {
        case .section(.teamLibrary):
            return .teamLibrarySection(title: WelcomeRowPresentation.title(for: .teamLibrary))
        case .section(let kind):
            return .section(title: WelcomeRowPresentation.title(for: kind))
        case .group(let id):
            guard let group = groupsById[id] else { return .empty }
            return .group(WelcomeRowPresentation.group(group, connectionCount: groupConnectionCounts[id] ?? 0))
        case .connection(let id, let section):
            if section.acceptsSavedConnections, let connection = connectionsById[id] {
                return .connection(savedRowModel(connection, section: section))
            }
            switch sharedConnectionsById[id] {
            case .linked(let linked):
                return .connection(WelcomeRowPresentation.sharedConnection(linked, section: section))
            case .team(let connection):
                let team = TeamLibrary.shared.content.connection(rowID: connection.id)
                return .connection(WelcomeRowPresentation.teamConnection(
                    connection, section: section, lastWriter: team?.lastWriter, lastChangedAt: team?.lastChangedAt
                ))
            case nil:
                return .empty
            }
        }
    }

    func renameGlyph(for row: LibraryRowID) -> NSImage? {
        switch row {
        case .group(let id):
            return WelcomeRowPresentation.renameGlyph(for: groupsById[id])
        case .connection(let id, _):
            return connectionsById[id].flatMap { WelcomeRowPresentation.renameGlyph(for: $0) }
        case .section:
            return nil
        }
    }

    private func savedRowModel(_ connection: DatabaseConnection, section: LibrarySectionKind) -> WelcomeConnectionRowModel {
        let group = connection.groupId.flatMap { groupsById[$0] }
        let groupPath = group.map { groupGraph.pathNames(to: $0.id) } ?? []
        let typeId = connection.type.pluginTypeId
        let isDriverRejected = services.pluginManager.rejectedPlugins.contains {
            $0.providedDatabaseTypeIds.contains(typeId)
        }
        return WelcomeRowPresentation.savedConnection(
            connection,
            section: section,
            tags: connection.tagIds.compactMap { tagsById[$0] },
            group: group,
            groupPath: groupPath,
            isDriverRejected: isDriverRejected
        )
    }
}
