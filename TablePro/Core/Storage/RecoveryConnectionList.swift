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
}
