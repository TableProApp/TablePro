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

    /// Safe to return nothing only because every caller runs it last, after validating through
    /// `isCurrent`. `TabExecutionRegistry.settle` is the same operation one level down and returns
    /// the answer instead, because its completion sites validate after releasing and cannot.
    mutating func finish(_ generation: Int, for connectionId: UUID) {
        guard generations[connectionId] == generation else { return }
        generations.removeValue(forKey: connectionId)
    }
}
