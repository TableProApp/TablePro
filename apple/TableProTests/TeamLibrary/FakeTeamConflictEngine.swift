//
//  FakeTeamConflictEngine.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
import TableProTestSupport

// The engine's conflicts table: a choice drops the conflict, as the core does once the store takes the kept side.
final class FakeTeamConflictEngine: TeamConflictEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [TeamConflictInfo]
    private var resolveFailure: CoreError?
    private var readFailure: CoreError?
    private var readGate: AsyncGate?
    private(set) var choices: [(record: SyncRecordRef, keep: ConflictChoiceTag)] = []
    private(set) var reads = 0

    init(_ conflicts: [TeamConflictInfo] = []) {
        held = conflicts
    }

    func set(_ conflicts: [TeamConflictInfo]) {
        lock.withLock { held = conflicts }
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

    func resolveConflict(record: SyncRecordRef, keep: ConflictChoiceTag) async throws {
        try lock.withLock {
            if let resolveFailure {
                throw resolveFailure
            }
            choices.append((record, keep))
            held.removeAll { $0.record == record }
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
        fields: [String] = ["query"],
        mine: [String: Any]? = ["name": "Orders", "query": "select mine"],
        theirs: [String: Any]? = ["name": "Orders", "query": "select theirs"]
    ) -> TeamConflictInfo {
        TeamConflictInfo(
            record: record(id, kind: kind),
            fields: fields,
            mine: mine.map(json),
            theirs: theirs.map(json)
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
