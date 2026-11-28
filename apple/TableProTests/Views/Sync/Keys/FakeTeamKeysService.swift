//
//  FakeTeamKeysService.swift
//  TableProTests
//

import Foundation
import os
@testable import TablePro
import TableProFFI

enum TeamKeysFixtures {
    static let teamID = "team_01h455vb4pex5vsknk084sn02q"
    static let ana = "0B5C4A1E-6F1D-4C4E-9A0B-3E1D2C3B4A51"
    static let bo = "1C6D5B2F-7A2E-4D5F-8B1C-4F2E3D4C5B62"
    static let you = "2D7E6C3A-8B3F-4E6A-9C2D-5A3F4E5D6C73"

    static let words = ["acorn", "badge", "cider", "delta", "ember", "fable"]
    static let otherWords = ["gable", "harbor", "ivory", "jungle", "kettle", "lantern"]
    static let qr = "TPF1:" + String(repeating: "A", count: 51) + "0"

    static func keysTeam(role: TeamRoleTag?) -> TeamKeysTeam {
        TeamKeysTeam(id: teamID, name: "Acme", role: role)
    }

    static func member(
        _ account: String,
        name: String? = nil,
        isYou: Bool = false,
        role: TeamRoleTag = .member,
        status: MemberKeyStatusTag
    ) -> TeamMemberKeys {
        TeamMemberKeys(account: account, name: name, email: nil, isYou: isYou, role: role, status: status)
    }

    static func snapshot(
        version: UInt32? = 3,
        state: KeyVersionStateTag = .ok,
        stoppedCause: StopCauseTag? = nil,
        rotationDue: Bool = false,
        holder: Bool = true,
        members: [TeamMemberKeys]? = nil,
        stoppedDevices: [TeamStoppedDevice] = []
    ) -> TeamKeysSnapshot {
        TeamKeysSnapshot(
            version: version,
            state: state,
            stoppedCause: stoppedCause,
            rotationDue: rotationDue,
            holder: holder,
            members: members ?? [
                member(you, name: "You Person", isYou: true, role: .admin, status: holder ? .holder : .awaitingConfirmation),
                member(ana, name: "Ana", role: .editor, status: .awaitingConfirmation),
                member(bo, name: "Bo", status: .alert),
            ],
            stoppedDevices: stoppedDevices
        )
    }

    static func notice(_ id: String, _ kind: KeyNoticeKindTag) -> KeyNoticeInfo {
        KeyNoticeInfo(id: id, kind: kind)
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

    static func rejected(_ code: String) -> CoreError {
        failure("sync.rejected", sync: .rejected(code: code))
    }
}

// The core's team key flows as the screens drive them: what they were asked, and what each answers.
final class FakeTeamKeysService: TeamKeysService, @unchecked Sendable {
    enum Call: Equatable {
        case create(team: String)
        case confirm(team: String, account: String)
        case accept(account: String, offeredIk: String, compared: Bool)
        case rotate(team: String, remove: [String])
        case restart(team: String, confirm: [String])
        case acceptRestart(team: String, signerIk: String)
        case compareQR(account: String, text: String)
        case dismiss(notice: String)
    }

    struct State {
        var snapshot = TeamKeysFixtures.snapshot()
        var notices: [KeyNoticeInfo] = []
        var credentials: [TeamCredentialToRotate] = []
        var fingerprints: [String: FingerprintInfo] = [:]
        var own = FingerprintInfo(words: TeamKeysFixtures.words, qr: TeamKeysFixtures.qr)
        var keyChanges: [String: KeyChangeInfo] = [:]
        var held: HeldRestartInfo?
        var matchingCodes: [String: String] = [:]
        // A failure per call name, thrown until it is cleared.
        var failures: [String: CoreError] = [:]
        var calls: [Call] = []
        var loads = 0
    }

    let state = OSAllocatedUnfairLock(uncheckedState: State())

    func update(_ change: (inout State) -> Void) {
        state.withLockUnchecked { change(&$0) }
    }

    func read<Value>(_ value: (State) -> Value) -> Value {
        state.withLockUnchecked { value($0) }
    }

    var calls: [Call] { read(\.calls) }

    private func answer<Value>(_ name: String, call: Call? = nil, _ value: (inout State) -> Value) throws -> Value {
        try state.withLockUnchecked { state in
            if let call { state.calls.append(call) }
            if let failure = state.failures[name] { throw failure }
            return value(&state)
        }
    }

    func teamKeys(team: String) async throws -> TeamKeysSnapshot {
        try answer("teamKeys") { state in
            state.loads += 1
            return state.snapshot
        }
    }

    func ownFingerprint() async throws -> FingerprintInfo {
        try answer("ownFingerprint") { $0.own }
    }

    func accountFingerprint(account: String) async throws -> FingerprintInfo {
        try answer("accountFingerprint") { state in
            state.fingerprints[account] ?? FingerprintInfo(words: TeamKeysFixtures.otherWords, qr: TeamKeysFixtures.qr)
        }
    }

    func compareFingerprintQr(account: String, text: String) async throws -> Bool {
        try answer("compareFingerprintQr", call: .compareQR(account: account, text: text)) { state in
            state.matchingCodes[account] == text
        }
    }

    func accountKeyChange(account: String) async throws -> KeyChangeInfo? {
        try answer("accountKeyChange") { $0.keyChanges[account] }
    }

    func acceptKeyChange(account: String, offeredIk: String, compared: Bool) async throws {
        try answer("acceptKeyChange", call: .accept(account: account, offeredIk: offeredIk, compared: compared)) { _ in }
    }

    func createTeamKeys(team: String) async throws {
        try answer("createTeamKeys", call: .create(team: team)) { _ in }
    }

    func confirmMember(team: String, account: String) async throws {
        try answer("confirmMember", call: .confirm(team: team, account: account)) { _ in }
    }

    func rotateTeamKey(team: String, remove: [String]) async throws {
        try answer("rotateTeamKey", call: .rotate(team: team, remove: remove)) { _ in }
    }

    func restartTeamKey(team: String, confirm: [String]) async throws {
        try answer("restartTeamKey", call: .restart(team: team, confirm: confirm)) { _ in }
    }

    func heldTeamRestart(team: String) async throws -> HeldRestartInfo? {
        try answer("heldTeamRestart") { $0.held }
    }

    func acceptTeamRestart(team: String, signerIk: String) async throws {
        try answer("acceptTeamRestart", call: .acceptRestart(team: team, signerIk: signerIk)) { _ in }
    }

    func credentialsToRotate(team: String) async throws -> [TeamCredentialToRotate] {
        try answer("credentialsToRotate") { $0.credentials }
    }

    func keyNotices() async throws -> [KeyNoticeInfo] {
        try answer("keyNotices") { $0.notices }
    }

    func dismissKeyNotice(notice: String) async throws {
        try answer("dismissKeyNotice", call: .dismiss(notice: notice)) { state in
            state.notices.removeAll { $0.id == notice }
        }
    }
}
