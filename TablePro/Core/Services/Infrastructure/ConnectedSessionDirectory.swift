//
//  ConnectedSessionDirectory.swift
//  TablePro
//

import Foundation

internal struct ConnectedSessionSummary: Identifiable, Equatable, Sendable {
    internal let id: UUID
    internal let name: String
    internal let databaseType: DatabaseType
    internal let databaseName: String
    internal let isReadOnly: Bool
}

@MainActor
internal enum ConnectedSessionDirectory {
    internal static func connectedSessions() -> [ConnectedSessionSummary] {
        summaries(
            of: Array(DatabaseManager.shared.activeSessions.values),
            hostedConnectionIds: WindowManager.shared.allConnectionIds()
        )
    }

    internal static func coordinator(for connectionId: UUID) -> MainContentCoordinator? {
        WindowManager.shared.coordinator(for: connectionId)
    }

    internal static func summaries(
        of sessions: [ConnectionSession],
        hostedConnectionIds: Set<UUID>
    ) -> [ConnectedSessionSummary] {
        sessions
            .filter { hostedConnectionIds.contains($0.id) && $0.reportedStatus.isConnected }
            .map { session in
                ConnectedSessionSummary(
                    id: session.id,
                    name: session.connection.name,
                    databaseType: session.connection.type,
                    databaseName: session.resolvedBrowseDatabase,
                    isReadOnly: session.safeModeLevel.blocksAllWrites
                )
            }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedStandardCompare(rhs.name)
                guard order == .orderedSame else { return order == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }
}
