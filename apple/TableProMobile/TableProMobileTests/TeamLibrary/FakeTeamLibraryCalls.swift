import Foundation
import os
import TableProFFI
@testable import TableProMobile

// The core engine's Team Library and team key calls as the iOS models drive them: what each was asked, and what it
// answers or throws next.
nonisolated final class FakeTeamLibraryCalls: TeamLibraryCalls, TeamKeysCalls, @unchecked Sendable {
    struct State {
        var teams: [TeamLibraryTeamInfo] = []
        var statuses: [TeamScopeStatusInfo] = []
        var unsent: [UnsentTeamEditInfo] = []
        var conflicts: [TeamConflictInfo] = []
        var publish = TeamPublishInfo(edits: 1, conflicts: 0, unsent: 0, problem: nil)
        var published: [(team: String, connections: [TeamConnectionArg])] = []
        var publishedQueries: [(team: String, folders: [TeamFolderArg], queries: [TeamQueryArg])] = []
        var removed: [(team: String, items: [TeamLibraryItemRef])] = []
        var discarded: [String?] = []
        var resolved: [(record: SyncRecordRef, keep: ConflictChoiceTag)] = []
        var deletes = 0
        var passes: [PassReasonTag] = []
        var reads = 0
        var failures: [String: [any Error]] = [:]

        var keys = TeamKeysSnapshot(
            version: 1,
            state: .ok,
            stoppedCause: nil,
            rotationDue: false,
            holder: true,
            members: [],
            stoppedDevices: []
        )
        var fingerprints: [String: FingerprintInfo] = [:]
        var confirmed: [String] = []
        var rotations = 0
        var restarts: [[String]] = []
        var notices: [KeyNoticeInfo] = []
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    func update(_ change: (inout State) -> Void) {
        state.withLockUnchecked { change(&$0) }
    }

    func read<Value>(_ value: (State) -> Value) -> Value {
        state.withLockUnchecked { value($0) }
    }

    func fail(_ name: String, with error: any Error) {
        update { $0.failures[name, default: []].append(error) }
    }

    private func check(_ name: String) throws {
        let error = state.withLockUnchecked { state -> (any Error)? in
            guard var queued = state.failures[name], !queued.isEmpty else { return nil }
            let first = queued.removeFirst()
            state.failures[name] = queued
            return first
        }
        if let error { throw error }
    }

    static func failure(_ code: String, sync: SyncFailureInfo? = nil) -> CoreError {
        .Failed(info: ErrorInfo(
            code: code,
            codes: [code],
            message: "",
            server: nil,
            path: nil,
            secret: nil,
            hostKey: nil,
            tlsFailure: nil,
            ai: nil,
            sync: sync,
            stepUp: nil
        ))
    }

    // MARK: - Team Library

    func teamLibrary() async throws -> [TeamLibraryTeamInfo] {
        try check("teamLibrary")
        return state.withLockUnchecked { state in
            state.reads += 1
            return state.teams
        }
    }

    func publishTeamConnections(teamId: String, connections: [TeamConnectionArg]) async throws -> TeamPublishInfo {
        try check("publish")
        return state.withLockUnchecked { state in
            state.published.append((teamId, connections))
            return state.publish
        }
    }

    func publishTeamSavedQueries(teamId: String, folders: [TeamFolderArg], queries: [TeamQueryArg]) async throws -> TeamPublishInfo {
        try check("publish")
        return state.withLockUnchecked { state in
            state.publishedQueries.append((teamId, folders, queries))
            return state.publish
        }
    }

    func removeTeamItems(teamId: String, items: [TeamLibraryItemRef]) async throws -> TeamPublishInfo {
        try check("remove")
        return state.withLockUnchecked { state in
            state.removed.append((teamId, items))
            return state.publish
        }
    }

    func unsentTeamEdits() async throws -> [UnsentTeamEditInfo] {
        try check("unsent")
        return read { $0.unsent }
    }

    func discardTeamEdits(teamId: String?) async throws {
        try check("discard")
        update { state in
            state.discarded.append(teamId)
            state.unsent.removeAll { teamId == nil || $0.teamId == teamId }
        }
    }

    func deleteTeamLibraryData() async throws {
        try check("delete")
        update { $0.deletes += 1 }
    }

    func teamScopeStatus() async throws -> [TeamScopeStatusInfo] {
        try check("status")
        return read { $0.statuses }
    }

    func syncNow(why: PassReasonTag) async throws {
        try check("syncNow")
        update { $0.passes.append(why) }
    }

    func conflicts() async throws -> [TeamConflictInfo] {
        try check("conflicts")
        return read { $0.conflicts }
    }

    func resolveConflict(record: SyncRecordRef, digest: String, keep: ConflictChoiceTag) async throws {
        try check("resolve")
        update { state in
            state.resolved.append((record, keep))
            state.conflicts.removeAll { $0.record == record }
        }
    }

    // MARK: - Team keys

    func teamKeys(team: String) async throws -> TeamKeysSnapshot {
        try check("teamKeys")
        return read { $0.keys }
    }

    func ownFingerprint() async throws -> FingerprintInfo {
        try check("ownFingerprint")
        return FingerprintInfo(words: ["one", "two", "three", "four", "five", "six"], qr: "TPF1:SELF")
    }

    func accountFingerprint(account: String) async throws -> FingerprintInfo {
        try check("accountFingerprint")
        return read { $0.fingerprints[account] } ?? FingerprintInfo(words: [account], qr: "TPF1:\(account)")
    }

    func accountKeyChange(account: String) async throws -> KeyChangeInfo? {
        try check("accountKeyChange")
        return nil
    }

    func acceptKeyChange(account: String, offeredIk: String, compared: Bool) async throws {
        try check("acceptKeyChange")
    }

    func createTeamKeys(team: String) async throws {
        try check("createTeamKeys")
    }

    func confirmMember(team: String, account: String) async throws {
        try check("confirmMember")
        update { $0.confirmed.append(account) }
    }

    func rotateTeamKey(team: String, remove: [String]) async throws {
        try check("rotateTeamKey")
        update { $0.rotations += 1 }
    }

    func restartTeamKey(team: String, confirm: [String]) async throws {
        try check("restartTeamKey")
        update { $0.restarts.append(confirm) }
    }

    func heldTeamRestart(team: String) async throws -> HeldRestartInfo? {
        try check("heldTeamRestart")
        return nil
    }

    func acceptTeamRestart(team: String, signerIk: String) async throws {
        try check("acceptTeamRestart")
    }

    func credentialsToRotate(team: String) async throws -> [TeamCredentialToRotate] {
        try check("credentialsToRotate")
        return []
    }

    func keyNotices() async throws -> [KeyNoticeInfo] {
        try check("keyNotices")
        return read { $0.notices }
    }

    func dismissKeyNotice(notice: String) async throws {
        try check("dismissKeyNotice")
        update { $0.notices.removeAll { $0.id == notice } }
    }
}

nonisolated enum TeamLibraryFixtures {
    static func team(
        _ id: String,
        name: String? = nil,
        role: TeamRoleTag? = .editor,
        canWrite: Bool = true,
        items: [TeamLibraryItemInfo] = []
    ) -> TeamLibraryTeamInfo {
        TeamLibraryTeamInfo(teamId: id, name: name, role: role, canWrite: canWrite, items: items)
    }

    static func connection(
        _ id: String,
        name: String,
        host: String = "db.example.com",
        extra: [String: Any] = [:],
        updatedBy: String? = nil,
        updatedAtMs: Int64? = nil
    ) -> TeamLibraryItemInfo {
        var fields: [String: Any] = [
            "name": name,
            "host": host,
            "port": 5432,
            "database": "app",
            "username": "reader",
            "type": "PostgreSQL",
        ]
        fields.merge(extra) { _, new in new }
        return TeamLibraryItemInfo(
            kind: .connection,
            id: id,
            fieldsJson: json(fields),
            updatedBy: updatedBy,
            updatedAtMs: updatedAtMs
        )
    }

    static func query(_ id: String, name: String, sql: String, folder: String? = nil, order: Int = 0) -> TeamLibraryItemInfo {
        var fields: [String: Any] = ["name": name, "query": sql, "sort_order": order]
        if let folder {
            fields["folder_client_id"] = folder
        }
        return TeamLibraryItemInfo(kind: .query, id: id, fieldsJson: json(fields), updatedBy: nil, updatedAtMs: nil)
    }

    static func folder(_ id: String, name: String) -> TeamLibraryItemInfo {
        TeamLibraryItemInfo(kind: .folder, id: id, fieldsJson: json(["name": name]), updatedBy: nil, updatedAtMs: nil)
    }

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }
}
