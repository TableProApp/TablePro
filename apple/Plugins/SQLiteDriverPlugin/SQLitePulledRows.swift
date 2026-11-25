//
//  SQLitePulledRows.swift
//  SQLiteDriverPlugin
//

import Foundation
import TableProPluginKit

// The pull side of one pulled read: the header on the first pull, a batch on each one after. A reader that lets go
// before the end finalizes the statement.
nonisolated final class SQLitePulledRows: @unchecked Sendable {
    private let backend: SQLiteLocalBackend
    private let query: String
    private let rules: SQLiteStatementRules
    private let id: UInt64
    private let lock = NSLock()
    private var started = false
    private var ended = false

    init(backend: SQLiteLocalBackend, query: String, rules: SQLiteStatementRules) {
        self.backend = backend
        self.query = query
        self.rules = rules
        id = backend.localCanceller.makeReadID()
    }

    deinit {
        guard lock.withLock({ started && !ended }) else { return }
        let backend = backend
        let id = id
        Task { await backend.endPulledRead(id) }
    }

    func next() async throws -> PluginStreamElement? {
        let backend = backend
        let canceller = backend.localCanceller
        let id = id
        let isFirst = lock.withLock {
            defer { started = true }
            return !started
        }
        do {
            return try await withTaskCancellationHandler {
                if isFirst {
                    return .header(try await backend.beginPulledRead(id, query: query, rules: rules))
                }
                guard let rows = try await backend.nextPulledBatch(id) else {
                    lock.withLock { ended = true }
                    return nil
                }
                return .rows(rows)
            } onCancel: {
                canceller.cancel(read: id)
            }
        } catch {
            lock.withLock { ended = true }
            throw error
        }
    }
}
