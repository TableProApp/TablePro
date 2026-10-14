//
//  RecoveryConnectionList.swift
//  TablePro
//

import Foundation

struct RecoveryCandidate {
    let connectionId: UUID
    let isActivated: Bool
    let retainsRestoreIntent: Bool
}

enum RecoveryConnectionList {
    static func connectionIds(from candidates: [RecoveryCandidate]) -> [UUID] {
        var seen = Set<UUID>()
        return candidates
            .filter { $0.isActivated || $0.retainsRestoreIntent }
            .map(\.connectionId)
            .filter { seen.insert($0).inserted }
    }

    /// A session a client launched that never showed a connection says nothing about the person's
    /// last one, so quitting it leaves the recovery list as it found it.
    static func shouldSaveOnQuit(_ connectionIds: [UUID], origin: AppSessionOrigin) -> Bool {
        !connectionIds.isEmpty || origin == .user
    }
}
