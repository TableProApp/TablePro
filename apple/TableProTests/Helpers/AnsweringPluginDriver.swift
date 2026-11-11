//
//  AnsweringPluginDriver.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport

// A plugin driver that answers each external statement from a closure, records what reached it, and with a `hold`
// keeps the statement in the driver until the test opens the gate.
final class AnsweringPluginDriver: PluginDriverStub, @unchecked Sendable {
    struct Sent {
        let query: String
        let rowCap: Int?
        let context: PluginStatementContext
    }

    var capabilities: PluginCapabilities { [.statementPolicy] }

    private let hold: AsyncGate?
    private let answer: @Sendable (String) -> PluginQueryResult
    private let lock = NSLock()
    private var received: [Sent] = []
    private var finished = 0

    init(hold: AsyncGate? = nil, answer: @escaping @Sendable (String) -> PluginQueryResult = { _ in .empty }) {
        self.hold = hold
        self.answer = answer
    }

    var sent: [Sent] {
        lock.withLock { received }
    }

    var finishedCount: Int {
        lock.withLock { finished }
    }

    func executeUserQuery(
        query: String,
        rowCap: Int?,
        parameters: [PluginCellValue]?,
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        lock.withLock { received.append(Sent(query: query, rowCap: rowCap, context: context)) }
        if let hold {
            await hold.wait()
        }
        lock.withLock { finished += 1 }
        return answer(query)
    }

    static func textRows(column: String, count: Int, bytes: Int, isTruncated: Bool = false) -> PluginQueryResult {
        PluginQueryResult(
            columns: [column],
            columnTypeNames: ["text"],
            rows: Array(repeating: [.text(String(repeating: "x", count: bytes))], count: count),
            rowsAffected: 0,
            executionTime: 0,
            isTruncated: isTruncated
        )
    }

    // Installed as the live session of a new connection, which the test removes.
    @MainActor
    static func install(_ driver: AnsweringPluginDriver, connection: DatabaseConnection) -> DatabaseScope {
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        session.browseDatabase = connection.database
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return DatabaseScope(connectionId: connection.id, database: connection.database, schema: nil)
    }
}

final class RecordingQueryHistory: QueryHistoryRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [QueryHistoryRecordRequest] = []

    var requests: [QueryHistoryRecordRequest] {
        lock.withLock { recorded }
    }

    func record(_ request: QueryHistoryRecordRequest) async -> Bool {
        lock.withLock { recorded.append(request) }
        return true
    }
}
