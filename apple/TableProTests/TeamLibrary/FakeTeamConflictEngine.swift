//
//  FakeTeamConflictEngine.swift
//  TableProTests
//

import CryptoKit
import Foundation
@testable import TablePro
import TableProFFI
import TableProTestSupport

// The engine's conflicts table: a choice on the digest listed drops the conflict, as the core does once the store takes
// the kept side; one on a conflict gone answers `sync.unknown`, one on a conflict replaced since `sync.changed`.
class FakeTeamConflictEngine: TeamConflictEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [TeamConflictInfo]
    private var resolveFailure: CoreError?
    private var readFailure: CoreError?
    private var readGate: AsyncGate?
    private var resolveGate: AsyncGate?
    private(set) var choices: [(record: SyncRecordRef, keep: ConflictChoiceTag)] = []
    private(set) var reads = 0
    private var waiting: [RecordApprovalInfo] = []
    private(set) var approvalDecisions: [(record: SyncRecordRef, field: String, approve: Bool)] = []

    init(_ conflicts: [TeamConflictInfo] = []) {
        held = conflicts
    }

    func set(_ conflicts: [TeamConflictInfo]) {
        lock.withLock { held = conflicts }
    }

    // The values pulls hold for the person, as the approval list gives them.
    func hold(approvals: [RecordApprovalInfo]) {
        lock.withLock { waiting = approvals }
    }

    func failResolves(with error: CoreError?) {
        lock.withLock { resolveFailure = error }
    }

    func failReads(with error: CoreError?) {
        lock.withLock { readFailure = error }
    }

    // The next read waits at the gate after it took the conflicts it answers with.
    func holdNextRead(at gate: AsyncGate) {
        lock.withLock { readGate = gate }
    }

    // The next choice waits at the gate before it reaches the conflicts.
    func holdNextResolve(at gate: AsyncGate) {
        lock.withLock { resolveGate = gate }
    }

    func conflicts() async throws -> [TeamConflictInfo] {
        let (answer, failure, gate) = lock.withLock { () -> ([TeamConflictInfo], CoreError?, AsyncGate?) in
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

    func resolveConflict(record: SyncRecordRef, digest: String, keep: ConflictChoiceTag) async throws {
        let gate = lock.withLock { () -> AsyncGate? in
            let gate = resolveGate
            resolveGate = nil
            return gate
        }
        await gate?.wait()
        try lock.withLock {
            if let resolveFailure {
                throw resolveFailure
            }
            guard let current = held.first(where: { $0.record == record }) else {
                throw TeamConflictFixture.failure("sync.unknown")
            }
            guard current.digest == digest else {
                throw TeamConflictFixture.failure("sync.changed")
            }
            choices.append((record, keep))
            held.removeAll { $0.record == record }
        }
    }

    func approvals() async throws -> [RecordApprovalInfo] {
        lock.withLock { waiting }
    }

    // A value decided by the digest listed leaves the list; one a pull changed since answers `sync.changed`.
    func decideApproval(record: SyncRecordRef, field: String, digest: String, approve: Bool) async throws {
        try lock.withLock {
            guard let index = waiting.firstIndex(where: { $0.record == record }),
                  let value = waiting[index].fields.first(where: { $0.field == field })
            else { throw TeamConflictFixture.failure("sync.unknown") }
            guard value.digest == digest else { throw TeamConflictFixture.failure("sync.changed") }
            approvalDecisions.append((record, field, approve))
            waiting[index].fields.removeAll { $0.field == field }
        }
    }
}

enum TeamConflictFixture {
    static let team = "team_01jdemo0000000000000000000"

    static func record(_ id: String = "q1", kind: String = "library_query", scope: String = team) -> SyncRecordRef {
        SyncRecordRef(scope: scope, kind: kind, recordId: id)
    }

    static func conflict(
        _ id: String = "q1",
        kind: String = "library_query",
        scope: String = team,
        fields: [String] = ["query"],
        mine: [String: Any]? = ["name": "Orders", "query": "select mine"],
        theirs: [String: Any]? = ["name": "Orders", "query": "select theirs"]
    ) -> TeamConflictInfo {
        let mine = mine.map(json)
        let theirs = theirs.map(json)
        let listed = [id, kind, fields.joined(separator: ","), mine ?? "-", theirs ?? "-"].joined(separator: "\n")
        return TeamConflictInfo(
            record: record(id, kind: kind, scope: scope),
            fields: fields,
            mine: mine,
            theirs: theirs,
            digest: SHA256.hash(data: Data(listed.utf8)).map { String(format: "%02x", $0) }.joined()
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

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
