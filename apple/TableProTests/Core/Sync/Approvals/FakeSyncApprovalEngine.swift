//
//  FakeSyncApprovalEngine.swift
//  TableProTests
//

import CryptoKit
import Foundation
@testable import TablePro
import TableProFFI
import TableProTestSupport

// The engine's approval queue: a decision on the digest listed drops the record, as the core does once the store takes
// the values or keeps its own; one on a record gone answers `sync.unknown`, one on a record a pull changed since
// `sync.changed`. The count is the records listed, as the core's `waiting_approvals` counts them.
final class FakeSyncApprovalEngine: SyncApprovalEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [RecordApprovalInfo]
    private var readFailure: CoreError?
    private var decideFailures: [String: CoreError] = [:]
    private var readGate: AsyncGate?
    private(set) var decisions: [(id: String, approve: Bool)] = []
    private(set) var reads = 0

    init(_ records: [RecordApprovalInfo] = []) {
        held = records
    }

    func set(_ records: [RecordApprovalInfo]) {
        lock.withLock { held = records }
    }

    func failReads(with error: CoreError?) {
        lock.withLock { readFailure = error }
    }

    func failDecision(on id: String, with error: CoreError) {
        lock.withLock { decideFailures[id] = error }
    }

    // The next read waits at the gate after it took the records it answers with.
    func holdNextRead(at gate: AsyncGate) {
        lock.withLock { readGate = gate }
    }

    var decided: [String] {
        lock.withLock { decisions.map { "\($0.id) \($0.approve ? "approve" : "reject")" } }
    }

    func status() -> SyncStatusInfo {
        let count = lock.withLock { UInt32(held.count) }
        return SyncStatusInfo(
            provider: .tableproSync,
            phase: .idle,
            lastPassMs: nil,
            lastSyncedMs: nil,
            problem: nil,
            waitingApprovals: count,
            conflicts: 0,
            held: 0,
            queuedChanges: 0
        )
    }

    func approvals() async throws -> [RecordApprovalInfo] {
        let (answer, failure, gate) = lock.withLock { () -> ([RecordApprovalInfo], CoreError?, AsyncGate?) in
            reads += 1
            let gate = readGate
            readGate = nil
            return (held, readFailure, gate)
        }
        await gate?.wait()
        if let failure {
            throw failure
        }
        return answer
    }

    func decideRecordApproval(record: SyncRecordRef, digest: String, approve: Bool) async throws {
        try lock.withLock {
            if let failure = decideFailures[record.recordId] {
                throw failure
            }
            guard let current = held.first(where: { $0.record == record }) else {
                throw SyncApprovalFixture.failure("sync.unknown")
            }
            guard current.digest == digest else {
                throw SyncApprovalFixture.failure("sync.changed")
            }
            decisions.append((record.recordId, approve))
            held.removeAll { $0.record == record }
        }
    }
}

enum SyncApprovalFixture {
    static let team = "team_01jdemo0000000000000000000"
    static let newID = "7E1D4C2A-8B0F-4A55-9C1E-2B6D3F4A5B6C"
    static let changedID = "1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D"

    static func record(_ id: String, kind: String = "connection", scope: String = "personal") -> SyncRecordRef {
        SyncRecordRef(scope: scope, kind: kind, recordId: id)
    }

    // A connection made on another Mac: every value is pulled, none is this Mac's.
    static func newConnection(
        _ id: String = newID,
        name: String? = "Orders Production",
        host: String = "db.example.com"
    ) -> RecordApprovalInfo {
        approval(record(id), name: name, isNew: true, fields: [
            ("/type", nil, "\"PostgreSQL\""),
            ("/host", nil, json(host)),
            ("/port", nil, "5432"),
            ("/database", nil, "\"orders\""),
            ("/username", nil, "\"app\""),
            ("/ssh_config/enabled", nil, "false"),
            ("/ssl_config/mode", nil, "\"Verify Identity\""),
            ("/startup_commands", nil, "\"\""),
            ("/additional_fields/tlsServerName", nil, "null")
        ])
    }

    // A connection this Mac has, whose host and Safe Mode another device changed.
    static func changedConnection(_ id: String = changedID, name: String? = "Analytics") -> RecordApprovalInfo {
        approval(record(id), name: name, isNew: false, fields: [
            ("/host", "\"analytics.internal\"", "\"analytics.example.net\""),
            ("/safe_mode_level", "\"readOnly\"", "\"silent\""),
            ("/startup_commands", nil, "\"SET search_path TO reporting;\\nSET statement_timeout = 0;\"")
        ])
    }

    static func approval(
        _ record: SyncRecordRef,
        name: String?,
        isNew: Bool,
        fields: [(String, String?, String?)]
    ) -> RecordApprovalInfo {
        let infos = fields.map { field, current, pulled in
            FieldApprovalInfo(field: field, current: current, pulled: pulled, digest: digest([field, pulled ?? "-"]))
        }
        return RecordApprovalInfo(
            record: record,
            name: name,
            newRecord: isNew,
            digest: digest([record.kind, record.recordId] + infos.map(\.digest)),
            fields: infos
        )
    }

    static func failure(_ code: String) -> CoreError {
        .Failed(info: ErrorInfo(
            code: code,
            codes: [code],
            message: code,
            server: nil,
            path: nil,
            secret: nil,
            hostKey: nil,
            tlsFailure: nil,
            ai: nil
        ))
    }

    static func json(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed])) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func digest(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
