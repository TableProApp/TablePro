import Foundation
import TableProFFI

// A team as the keys screen reads it: its scope name (`team_...`), its name and this person's role in it.
nonisolated struct TeamKeysTeam: Hashable, Sendable {
    let id: String
    let name: String
    let role: TeamRoleTag?

    init(id: String, name: String, role: TeamRoleTag?) {
        self.id = id
        self.name = name
        self.role = role
    }

    init(_ team: TeamLibraryTeam) {
        self.init(id: team.id, name: team.name, role: team.role)
    }

    // Owners and admins confirm members and rotate at any time (core ADR 0056, Teams).
    var managesKeys: Bool {
        role == .owner || role == .admin
    }
}

nonisolated struct TeamMemberKeys: Equatable, Sendable, Identifiable {
    let account: String
    let name: String?
    let email: String?
    let isYou: Bool
    let role: TeamRoleTag
    let status: MemberKeyStatusTag

    var id: String { account }

    var displayName: String {
        (name ?? email).map(TeamLibraryVisibleText.name) ?? String(localized: "Unknown person")
    }
}

nonisolated struct TeamStoppedDevice: Equatable, Sendable, Identifiable {
    let account: String
    let device: String
    let ownerName: String?
    let version: UInt32
    let canReconfirm: Bool

    var id: String { device }
}

// A secret a removed party could read: the connection that holds it, by name and driver while this device still has
// it, and the envelope table's secret kind, such as `password` or `plugin.<field id>` (core ADR 0056, Old data).
nonisolated struct TeamCredentialToRotate: Equatable, Sendable, Identifiable {
    let envelope: String
    let connectionName: String?
    let driver: String?
    let fieldKey: String

    var id: String { envelope }
}

nonisolated struct TeamKeysSnapshot: Equatable, Sendable {
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

    init(
        version: UInt32?,
        state: KeyVersionStateTag,
        stoppedCause: StopCauseTag?,
        rotationDue: Bool,
        holder: Bool,
        members: [TeamMemberKeys],
        stoppedDevices: [TeamStoppedDevice]
    ) {
        self.version = version
        self.state = state
        self.stoppedCause = stoppedCause
        self.rotationDue = rotationDue
        self.holder = holder
        self.members = members
        self.stoppedDevices = stoppedDevices
    }

    init(_ info: TeamKeysInfo) {
        self.init(
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
                    ownerName: ($0.name ?? $0.email).map(TeamLibraryVisibleText.name),
                    version: $0.version,
                    canReconfirm: $0.canReconfirm
                )
            }
        )
    }
}

// The team key flows of the core's sync service (core ADR 0056, Pins and Teams), so the screens run over a fake.
nonisolated protocol TeamKeysCalls: AnyObject, Sendable {
    func teamKeys(team: String) async throws -> TeamKeysSnapshot
    func ownFingerprint() async throws -> FingerprintInfo
    func accountFingerprint(account: String) async throws -> FingerprintInfo
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

// Every call goes to the key service the host has open now, so a sign-in change reaches the next one.
nonisolated final class TeamKeysLiveCalls: TeamKeysCalls, @unchecked Sendable {
    private let service: @Sendable () async throws -> SyncService

    init(service: @escaping @Sendable () async throws -> SyncService) {
        self.service = service
    }

    @MainActor
    convenience init(host: IOSSyncEngineHost) {
        self.init(service: { try await host.keyService() })
    }

    func teamKeys(team: String) async throws -> TeamKeysSnapshot {
        TeamKeysSnapshot(try await service().teamKeys(team: team))
    }

    func ownFingerprint() async throws -> FingerprintInfo {
        try await service().ownFingerprint()
    }

    func accountFingerprint(account: String) async throws -> FingerprintInfo {
        try await service().accountFingerprint(account: account)
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
        try await service().credentialsToRotate(scope: team).map {
            TeamCredentialToRotate(
                envelope: $0.envelope,
                connectionName: $0.connectionName.map(TeamLibraryVisibleText.name),
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
}
