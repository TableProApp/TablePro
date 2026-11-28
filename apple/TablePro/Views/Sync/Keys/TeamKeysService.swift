//
//  TeamKeysService.swift
//  TablePro
//

import Foundation
import TableProFFI

// A team as the account's profile names it: its scope name (`team_...`), its name and this person's role in it.
nonisolated internal struct TeamKeysTeam: Hashable, Sendable {
    let id: String
    let name: String
    let role: TeamRoleTag?

    init(id: String, name: String, role: TeamRoleTag?) {
        self.id = id
        self.name = name
        self.role = role
    }

    init(_ membership: AccountMembership) {
        self.init(id: membership.teamID, name: membership.teamName, role: Self.role(membership.role))
    }

    // Owners and admins confirm members and rotate at any time (core ADR 0056, Teams).
    var managesKeys: Bool {
        role == .owner || role == .admin
    }

    static func role(_ code: String) -> TeamRoleTag? {
        switch code {
        case "owner": .owner
        case "admin": .admin
        case "editor": .editor
        case "member": .member
        default: nil
        }
    }
}

nonisolated internal struct TeamMemberKeys: Equatable, Sendable, Identifiable {
    let account: String
    let name: String?
    let email: String?
    let isYou: Bool
    let role: TeamRoleTag
    let status: MemberKeyStatusTag

    var id: String { account }

    var displayName: String {
        name ?? email ?? String(localized: "Unknown person")
    }
}

nonisolated internal struct TeamStoppedDevice: Equatable, Sendable, Identifiable {
    let account: String
    let device: String
    let ownerName: String?
    let deviceName: String?
    let version: UInt32
    let canReconfirm: Bool

    var id: String { device }
}

// A secret a removed party could read: the connection that holds it, by name and driver while this Mac still has it,
// and the envelope table's secret kind, such as `password` or `plugin.<field id>` (core ADR 0056, Old data).
nonisolated internal struct TeamCredentialToRotate: Equatable, Sendable, Identifiable {
    let envelope: String
    let connectionName: String?
    let driver: String?
    let fieldKey: String

    var id: String { envelope }
}

nonisolated internal struct TeamKeysSnapshot: Equatable, Sendable {
    let version: UInt32?
    let state: KeyVersionStateTag
    let stoppedCause: StopCauseTag?
    let rotationDue: Bool
    let holder: Bool
    let members: [TeamMemberKeys]
    let stoppedDevices: [TeamStoppedDevice]

    func member(_ account: String) -> TeamMemberKeys? {
        members.first { $0.account == account }
    }
}

// The team key flows of the core's sync service (core ADR 0056, Pins and Teams), so the screens run over a fake.
nonisolated internal protocol TeamKeysService: AnyObject, Sendable {
    func teamKeys(team: String) async throws -> TeamKeysSnapshot
    func ownFingerprint() async throws -> FingerprintInfo
    func accountFingerprint(account: String) async throws -> FingerprintInfo
    func compareFingerprintQr(account: String, text: String) async throws -> Bool
    func accountKeyChange(account: String) async throws -> KeyChangeInfo?
    func acceptKeyChange(account: String, offeredIk: String, compared: Bool) async throws
    func createTeamKeys(team: String) async throws
    func confirmMember(team: String, account: String) async throws
    func rotateTeamKey(team: String, remove: [String]) async throws
    func restartTeamKey(team: String, confirm: [String]) async throws
    func heldTeamRestart(team: String) async throws -> HeldRestartInfo?
    func acceptTeamRestart(team: String, signerIk: String) async throws
    func credentialsToRotate(team: String) async throws -> [TeamCredentialToRotate]
    func keyNotices() async throws -> [KeyNoticeInfo]
    func dismissKeyNotice(notice: String) async throws
}
