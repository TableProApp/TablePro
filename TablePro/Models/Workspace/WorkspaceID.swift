//
//  WorkspaceID.swift
//  TablePro
//

import Foundation

/// One place the user works: a connection plus the container it is browsing.
///
/// The container is a database on most engines and a schema on the ones that switch
/// schemas instead, which is what `ContainerSwitchTarget` decides. An engine that
/// switches neither has a single unnamed container, so it has exactly one workspace.
internal struct WorkspaceID: Hashable, Codable, Identifiable, Sendable {
    internal let connectionId: UUID
    internal let container: String

    internal init(connectionId: UUID, container: String) {
        self.connectionId = connectionId
        self.container = container
    }

    internal var id: WorkspaceID { self }
}
