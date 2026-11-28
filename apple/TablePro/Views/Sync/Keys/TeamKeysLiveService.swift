//
//  TeamKeysLiveService.swift
//  TablePro
//

import Foundation
import TableProFFI

internal final class TeamKeysLiveService: TeamKeysService {
    static let shared = TeamKeysLiveService()

    private let service: @Sendable () async throws -> SyncService

    init(service: @escaping @Sendable () async throws -> SyncService = { try await SyncEngineHost.shared.keyService() }) {
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
        let credentials = try await service().credentialsToRotate(scope: team)
        return credentials.map {
            TeamCredentialToRotate(
                envelope: $0.envelope,
                connectionName: $0.connectionName,
                driver: $0.connectionDriver,
                fieldKey: $0.field
            )
        }
    }

    func keyNotices() async throws -> [KeyNoticeInfo] {
        try await service().keyNotices()
    }

    func dismissKeyNotice(notice: String) async throws {
        try await service().dismissKeyNotice(notice: notice)
    }

    static func snapshot(_ info: TeamKeysInfo) -> TeamKeysSnapshot {
        TeamKeysSnapshot(
            version: info.version,
            state: info.state,
            stoppedCause: info.stoppedCause,
            rotationDue: info.rotationDue,
            holder: info.holder,
            members: info.members.map {
                TeamMemberKeys(account: $0.account, name: $0.name, email: $0.email, isYou: $0.isSelf, role: $0.role, status: $0.status)
            },
            stoppedDevices: info.stopped.map {
                TeamStoppedDevice(
                    account: $0.account,
                    device: $0.device,
                    ownerName: $0.name ?? $0.email,
                    deviceName: nil,
                    version: $0.version,
                    canReconfirm: $0.canReconfirm
                )
            }
        )
    }
}
