//
//  TeamKeysLiveService.swift
//  TablePro
//

import Foundation
import TableProFFI

internal struct TeamKeysEngineMissing: Error {}

// The key screens reach the one sync service `SyncEngineHost` opened over the account (core ADR 0054).
@MainActor
internal enum TeamKeysEngine {
    static func service() async throws -> SyncService {
        let engine = try await SyncEngineHost.shared.engine()
        guard let service = engine as? SyncService else { throw TeamKeysEngineMissing() }
        return service
    }
}

internal final class TeamKeysLiveService: TeamKeysService {
    static let shared = TeamKeysLiveService()

    private let service: @Sendable () async throws -> SyncService

    init(service: @escaping @Sendable () async throws -> SyncService = { try await TeamKeysEngine.service() }) {
        self.service = service
    }

    func teamKeys(team: String) async throws -> TeamKeysSnapshot {
        let info = try await service().teamKeys(team: team)
        return Self.snapshot(info)
    }

    func ownFingerprint() async throws -> FingerprintInfo {
        try await service().ownFingerprint()
    }

    func accountFingerprint(account: String) async throws -> FingerprintInfo {
        try await service().accountFingerprint(account: account)
    }

    func compareFingerprintQr(account: String, text: String) async throws -> Bool {
        try await service().compareFingerprintQr(account: account, text: text)
    }

    func accountKeyChange(account: String) async throws -> KeyChangeInfo? {
        try await service().accountKeyChange(account: account)
    }

    func acceptKeyChange(account: String, offeredIk: String, compared: Bool) async throws {
        try await service().acceptKeyChange(account: account, offeredIk: offeredIk, compared: compared)
    }

    func createTeamKeys(team: String) async throws {
        try await service().createTeamKeys(team: team)
    }

    func confirmMember(team: String, account: String) async throws {
        try await service().confirmMember(team: team, account: account)
    }

    func rotateTeamKey(team: String, remove: [String]) async throws {
        try await service().rotateTeamKey(team: team, remove: remove)
    }

    func restartTeamKey(team: String, confirm: [String]) async throws {
        try await service().restartTeamKey(team: team, confirm: confirm)
    }

    func heldTeamRestart(team: String) async throws -> HeldRestartInfo? {
        try await service().heldTeamRestart(team: team)
    }

    func acceptTeamRestart(team: String, signerIk: String) async throws {
        try await service().acceptTeamRestart(team: team, signerIk: signerIk)
    }

    func credentialsToRotate(team: String) async throws -> [TeamCredentialToRotate] {
        let envelopes = try await service().credentialsToRotate(scope: team)
        return envelopes.map { TeamCredentialToRotate(envelope: $0, connectionName: nil, secret: nil) }
    }

    func keyNotices() async throws -> [KeyNoticeInfo] {
        try await service().keyNotices()
    }

    func dismissKeyNotice(notice: String) async throws {
        try await service().dismissKeyNotice(notice: notice)
    }

    // The core names no person yet: lane K8 adds names, emails and this account's own row to these records.
    static func snapshot(_ info: TeamKeysInfo) -> TeamKeysSnapshot {
        TeamKeysSnapshot(
            version: info.version,
            state: info.state,
            stoppedCause: info.stoppedCause,
            rotationDue: info.rotationDue,
            holder: info.holder,
            members: info.members.map {
                TeamMemberKeys(account: $0.account, name: nil, email: nil, isYou: false, role: $0.role, status: $0.status)
            },
            stoppedDevices: info.stopped.map {
                TeamStoppedDevice(
                    account: $0.account,
                    device: $0.device,
                    ownerName: nil,
                    deviceName: nil,
                    version: $0.version,
                    canReconfirm: $0.canReconfirm
                )
            }
        )
    }
}
