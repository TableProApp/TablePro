import Foundation
import TableProModels

nonisolated struct TagDeletionRequest: Equatable, Sendable {
    let tag: ConnectionTag
    let connectionCount: Int

    var message: String {
        switch connectionCount {
        case 0:
            String(format: String(localized: "“%@” is not on any connection."), tag.name)
        case 1:
            String(format: String(localized: "“%@” will be removed from 1 connection."), tag.name)
        default:
            String(format: String(localized: "“%@” will be removed from %d connections."), tag.name, connectionCount)
        }
    }
}
