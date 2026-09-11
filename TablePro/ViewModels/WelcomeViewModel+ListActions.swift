//
//  WelcomeViewModel+ListActions.swift
//  TablePro
//

import Combine
import Foundation

extension WelcomeViewModel {
    func rowMetadata(for connection: DatabaseConnection) -> (tags: [ConnectionTag], group: ConnectionGroup?) {
        ConnectionMetadata.resolve(connection: connection, tags: tags, groups: groups)
    }

    func setIncludedInSync(_ targets: [DatabaseConnection], included: Bool) {
        let ids = Set(targets.map(\.id))
        var updated: [DatabaseConnection] = []
        for index in connections.indices where ids.contains(connections[index].id) {
            connections[index].localOnly = !included
            updated.append(connections[index])
        }
        guard services.connectionStorage.updateConnections(updated) else {
            connections = services.connectionStorage.loadConnections()
            rebuildTree()
            return
        }
        rebuildTree()
        services.appEvents.connectionUpdated.send(targets.count == 1 ? targets.first?.id : nil)
    }

    func connectionString(for connection: DatabaseConnection) -> String {
        let storage = services.connectionStorage
        let password = storage.loadPassword(for: connection.id)
        guard let profileId = connection.sshProfileId else {
            return ConnectionURLFormatter.format(
                connection,
                password: password,
                sshPassword: storage.loadSSHPassword(for: connection.id),
                sshProfile: nil
            )
        }
        let profiles = services.sshProfileStorage
        return ConnectionURLFormatter.format(
            connection,
            password: password,
            sshPassword: profiles.loadSSHPassword(for: profileId),
            sshProfile: profiles.profile(for: profileId)
        )
    }

    func externalConnections(for ids: Set<UUID>) -> [LinkedConnection] {
        (visibleLinkedConnections + visibleTeamLibraryConnections).filter { ids.contains($0.id) }
    }

    func isLinkedFolderConnection(_ id: UUID) -> Bool {
        linkedConnections.contains { $0.id == id }
    }
}
