//
//  OnceTask.swift
//  TablePro
//

import Foundation

actor OnceTask<Key: Hashable & Sendable, Value: Sendable> {
    private struct Entry {
        let task: Task<Value, Error>
        let generation: Int
    }

    private var inFlight: [Key: Entry] = [:]
    private var nextGeneration: Int = 0

    init() {}

    func execute(
        key: Key,
        work: @Sendable @escaping () async throws -> Value
    ) async throws -> Value {
        if let existing = inFlight[key] {
            return try await existing.task.value
        }

        nextGeneration += 1
        let generation = nextGeneration
        let task = Task<Value, Error> {
            try await work()
        }
        inFlight[key] = Entry(task: task, generation: generation)
        defer {
            if inFlight[key]?.generation == generation {
                inFlight.removeValue(forKey: key)
            }
        }
        return try await task.value
    }

    func cancel(key: Key) {
        inFlight[key]?.task.cancel()
        inFlight.removeValue(forKey: key)
    }

    func cancelAll() {
        for entry in inFlight.values {
            entry.task.cancel()
        }
        inFlight.removeAll()
    }
}
