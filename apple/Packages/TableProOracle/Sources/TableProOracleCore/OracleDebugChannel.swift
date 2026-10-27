import Foundation

// A database session a debug engine sends its statements on: the target, the DBMS_DEBUG supervisor or the JDWP helper.
protocol OracleDebugChannel: AnyObject, Sendable {
    func executeDirect(_ sql: String, binds: [OracleBindValue], autoCommit: Bool, readsRows: Bool) async throws -> [String?]
    func executeQuery(_ query: String) async throws -> OracleRawResult
    func cancelCurrentQuery()
}

extension OracleDebugChannel {
    func executeDirect(_ sql: String, binds: [OracleBindValue] = [], readsRows: Bool = false) async throws -> [String?] {
        try await executeDirect(sql, binds: binds, autoCommit: false, readsRows: readsRows)
    }
}

extension OracleCoreConnection: OracleDebugChannel {}
