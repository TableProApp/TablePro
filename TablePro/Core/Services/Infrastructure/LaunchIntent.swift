//
//  LaunchIntent.swift
//  TablePro
//

import Foundation
import TableProImport

internal enum LaunchIntent: @unchecked Sendable {
    case openConnection(UUID)
    case openTable(
        connectionId: UUID,
        database: String?,
        schema: String?,
        table: String,
        isView: Bool,
        objectType: TableInfo.TableType? = nil
    )
    case openQuery(connectionId: UUID, sql: String)
    case openAgentSession(connectionId: UUID, prompt: String?)
    case importConnection(ConnectionBundle)
    case openSQLFile(URL)
    case openDatabaseFile(URL, DatabaseType)
    case openDataFile(URL)
    case openConnectionShare(URL)
    case pairIntegration(PairingRequest)
    case startMCPServer
    /// nil opens the last-used pane.
    case openSettings(SettingsPane?)
    case openDatabaseURL(URL)
    case installPlugin(URL)
    case reopenClosedTab(RecentlyClosedTabEntry)
    case openSampleDatabase

    internal var targetConnectionId: UUID? {
        switch self {
        case .openConnection(let id),
             .openTable(let id, _, _, _, _, _),
             .openQuery(let id, _),
             .openAgentSession(let id, _):
            return id
        case .reopenClosedTab(let entry):
            return entry.connectionId
        case .openSampleDatabase,
             .openDatabaseURL,
             .openDatabaseFile,
             .openDataFile,
             .openSQLFile,
             .importConnection,
             .openConnectionShare,
             .pairIntegration,
             .startMCPServer,
             .openSettings,
             .installPlugin:
            return nil
        }
    }
}
