//
//  RecoveryConnectionList.swift
//  TablePro
//

import Foundation

struct RecoveryCandidate {
    let connectionId: UUID
    let isActivated: Bool
}

enum RecoveryConnectionList {
    static func connectionIds(from candidates: [RecoveryCandidate]) -> [UUID] {
        var seen = Set<UUID>()
        return candidates
            .filter(\.isActivated)
            .map(\.connectionId)
            .filter { seen.insert($0).inserted }
    }
}
