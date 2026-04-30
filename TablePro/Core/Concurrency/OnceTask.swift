//
//  OnceTask.swift
//  TablePro
//

import Foundation

actor OnceTask<Key: Hashable & Sendable, Value: Sendable> {
    private var inFlight: [Key: Task<Value, Error>] = [:]

    init() {}

    func execute(
        key: Key,
        work: @Sendable @escaping () async throws -> Value
    ) async throws -> Value {
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let task = Task<Value, Error> {
            try await work()
        }
        inFlight[key] = task
        defer { inFlight.removeValue(forKey: key) }
        return try await task.value
    }

    func cancel(key: Key) {
        inFlight[key]?.cancel()
        inFlight.removeValue(forKey: key)
    }

    func cancelAll() {
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
    }
}
