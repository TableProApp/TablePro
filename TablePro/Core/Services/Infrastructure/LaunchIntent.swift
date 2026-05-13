//
//  LaunchIntent.swift
//  TablePro
//

import Foundation

internal enum LaunchIntent: @unchecked Sendable {
    case openConnection(UUID)
    case openTable(connectionId: UUID, database: String?, schema: String?, table: String, isView: Bool)
    case openQuery(connectionId: UUID, sql: String)
    case importConnection(ExportableConnection)
    case openSQLFile(URL)
    case openDatabaseFile(URL, DatabaseType)
    case openConnectionShare(URL)
    case pairIntegration(PairingRequest)
    case startMCPServer
    case openDatabaseURL(URL)
    case installPlugin(URL)

    internal var targetConnectionId: UUID? {
        switch self {
        case .openConnection(let id),
             .openTable(let id, _, _, _, _),
             .openQuery(let id, _):
            return id
        case .openDatabaseURL,
             .openDatabaseFile,
             .openSQLFile,
             .importConnection,
             .openConnectionShare,
             .pairIntegration,
             .startMCPServer,
             .installPlugin:
            return nil
        }
    }
}
