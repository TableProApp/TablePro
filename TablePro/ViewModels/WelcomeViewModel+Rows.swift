//
//  WelcomeViewModel+Rows.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary

extension WelcomeViewModel {
    func rowModel(for row: LibraryRowID) -> WelcomeRowModel {
        switch row {
        case .section(let kind):
            return .section(title: WelcomeRowPresentation.title(for: kind))
        case .group(let id):
            guard let group = groupsById[id] else { return .empty }
            return .group(WelcomeGroupRowModel(
                id: id,
                name: group.name,
                color: group.color,
                connectionCount: groupConnectionCounts[id] ?? 0
            ))
        case .connection(let id, let section):
            if section.acceptsSavedConnections, let connection = connectionsById[id] {
                return .connection(savedRowModel(connection, section: section))
            }
            guard let shared = sharedConnectionsById[id] else { return .empty }
            return .connection(WelcomeRowPresentation.sharedConnection(shared, section: section))
        }
    }

    private func savedRowModel(_ connection: DatabaseConnection, section: LibrarySectionKind) -> WelcomeConnectionRowModel {
        let group = connection.groupId.flatMap { groupsById[$0] }
        let groupPath = group.map { groupGraph.pathNames(to: $0.id) } ?? []
        let typeId = connection.type.pluginTypeId
        let isDriverRejected = services.pluginManager.rejectedPlugins.contains { rejected in
            rejected.bundleId == typeId || rejected.registryId == typeId
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
