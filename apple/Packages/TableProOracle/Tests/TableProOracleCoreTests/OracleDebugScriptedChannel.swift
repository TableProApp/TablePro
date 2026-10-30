import Foundation
import os
@testable import TableProOracleCore

// A database session that answers each statement through `respond` and records it as asked. Statements take turns on
// a gate as on `OracleCoreConnection`, so one that never returns holds up every later one.
final class ScriptedChannel: OracleDebugChannel, @unchecked Sendable {
    private let gate = QueryGate()
    private let asked = OSAllocatedUnfairLock(initialState: [String]())
    private let rows: [[OracleRawCell]]
    private let respond: @Sendable (String) async throws -> [String?]

    init(rows: [[OracleRawCell]] = [], respond: @escaping @Sendable (String) async throws -> [String?] = { _ in [] }) {
        self.rows = rows
        self.respond = respond
    }

    var sent: [String] { asked.withLock { $0 } }

    func executeDirect(_ sql: String, binds: [OracleBindValue], autoCommit: Bool, readsRows: Bool) async throws -> [String?] {
        asked.withLock { $0.append(sql) }
        await gate.acquire()
        do {
            let answer = try await respond(sql)
            await gate.release()
            return answer
        } catch {
            await gate.release()
            throw error
        }
    }

    func executeQuery(_ query: String) async throws -> OracleRawResult {
        asked.withLock { $0.append(query) }
        return OracleRawResult(columns: [], rows: rows, affectedRows: 0, isTruncated: false)
    }

    func cancelCurrentQuery() {}
}

final class Latch: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (isOpen: false, waiters: [CheckedContinuation<Void, Never>]()))

    func wait() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { current -> Bool in
                if !current.isOpen { current.waiters.append(continuation) }
                return current.isOpen
            }
            if isOpen { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { current -> [CheckedContinuation<Void, Never>] in
            current.isOpen = true
            defer { current.waiters.removeAll() }
            return current.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

// Nil when `body` has not returned within `seconds`, so a call that hangs fails its test instead of the whole run.
func finished<T: Sendable>(within seconds: Double, _ body: @escaping @Sendable () async throws -> T) async -> T? {
    let task = Task { try? await body() }
    return await OracleDebugSupport.value(of: task, within: seconds) ?? nil
}
