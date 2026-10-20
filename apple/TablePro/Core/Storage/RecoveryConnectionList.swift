//
//  RecoveryConnectionList.swift
//  TablePro
//

import Foundation

struct RecoveryCandidate {
    let connectionId: UUID
    let openedAt: Date
    let phase: ConnectionWindowPhase
    let isActivated: Bool
}

struct LastSession: Codable, Equatable {
    struct Connection: Codable, Equatable {
        let id: UUID
        let reconnects: Bool
    }

    var connections: [Connection]
    var shownConnectionId: UUID?

    static let empty = LastSession(connections: [], shownConnectionId: nil)

    var reconnectingIds: [UUID] {
        connections.filter(\.reconnects).map(\.id)
    }
}

enum RecoveryConnectionList {
    // Every strip entry comes back, but a canceled or user-ended one never dials again (#1358).
    // Ordered by openedAt, which is how the strip ranks entries nobody dragged.
    static func lastSession(
        from candidates: [RecoveryCandidate],
        endedByUser: (UUID) -> Bool = { _ in false },
        shownConnectionId: UUID?
    ) -> LastSession {
        var openedAt: [UUID: Date] = [:]
        var reconnects: [UUID: Bool] = [:]
        for candidate in candidates where candidate.phase != .closing {
            let id = candidate.connectionId
            openedAt[id] = min(openedAt[id] ?? candidate.openedAt, candidate.openedAt)
            let wantsConnection = candidate.isActivated
                || ConnectionWindowPhaseMachine.retainsRestoreIntent(phase: candidate.phase)
            reconnects[id] = (reconnects[id] ?? false) || wantsConnection
        }

        let ordered = openedAt.keys.sorted { lhs, rhs in
            let left = openedAt[lhs] ?? .distantFuture
            let right = openedAt[rhs] ?? .distantFuture
            guard left == right else { return left < right }
            return lhs.uuidString < rhs.uuidString
        }
        let connections = ordered.map { id in
            LastSession.Connection(id: id, reconnects: (reconnects[id] ?? false) && !endedByUser(id))
        }
        let shown = shownConnectionId.flatMap { openedAt[$0] == nil ? nil : $0 }
        return LastSession(connections: connections, shownConnectionId: shown)
    }

    // A client-launched session that never showed a connection says nothing about the user's last one.
    static func shouldSaveOnQuit(_ session: LastSession, origin: AppSessionOrigin) -> Bool {
        !session.connections.isEmpty || origin == .user
    }
}
