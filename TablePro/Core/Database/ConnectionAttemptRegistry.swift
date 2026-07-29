//
//  ConnectionAttemptRegistry.swift
//  TablePro
//

import Foundation

struct ConnectionAttemptRegistry {
    private var generations: [UUID: Int] = [:]
    private var lastGeneration: Int = 0

    mutating func begin(for connectionId: UUID) -> Int {
        lastGeneration += 1
        generations[connectionId] = lastGeneration
        return lastGeneration
    }

    func isCurrent(_ generation: Int, for connectionId: UUID) -> Bool {
        generations[connectionId] == generation
    }

    mutating func invalidate(for connectionId: UUID) {
        generations.removeValue(forKey: connectionId)
    }

    mutating func finish(_ generation: Int, for connectionId: UUID) {
        guard generations[connectionId] == generation else { return }
        generations.removeValue(forKey: connectionId)
    }
}
