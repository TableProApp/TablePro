//
//  ConnectionFormRequest.swift
//  TablePro
//

import Foundation

internal enum ConnectionFormRequest: Codable, Hashable {
    case edit(connectionId: UUID)
    case create(draftId: UUID)
    // A Team Library connection, by its team and the lowercase id the team stores it under.
    case editTeamCopy(teamID: String, itemID: String)

    internal var editedConnectionId: UUID? {
        guard case .edit(let connectionId) = self else { return nil }
        return connectionId
    }

    internal var draftId: UUID? {
        guard case .create(let draftId) = self else { return nil }
        return draftId
    }
}
