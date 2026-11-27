import Combine
import Foundation
import Observation
import os
import TableProFFI

nonisolated struct TeamActionFailure: Equatable, Identifiable, Sendable {
    let title: String
    let message: String

    var id: String { title + "\n" + message }
}

// The words a sheet loads, with the states a load can be in.
nonisolated enum TeamFingerprintLoad: Equatable, Sendable {
    case loading
    case loaded(FingerprintInfo)
    case failed(String)
}

// One team's keys screen: the team key's state, its members' keys, the devices stopped on it and what a removed party
// could read (core ADR 0056, Pins and Teams), as the Mac's TeamKeysModel shows them.
@MainActor @Observable
final class TeamKeysModel {
    enum Sheet: Identifiable, Equatable {
        case confirm(TeamMemberKeys)
        case keyChange(TeamMemberKeys)
        case heldRestart
        case restart
        case ownWords

        var id: String {
            switch self {
            case .confirm(let member): "confirm-\(member.account)"
            case .keyChange(let member): "key-change-\(member.account)"
            case .heldRestart: "held-restart"
            case .restart: "restart"
            case .ownWords: "own-words"
            }
        }
    }

    enum Work: Equatable {
        case creating
        case rotating
        case restarting
        case acceptingRestart
        case confirming(String)
        case accepting(String)
        case dismissing(String)
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "TeamKeys")

    private(set) var snapshot: TeamKeysSnapshot?
    private(set) var notices: [TeamKeyNotice] = []
    private(set) var credentials: [TeamCredentialToRotate] = []
    private(set) var isLoading = false
    private(set) var loadFailure: String?
    private(set) var work: Work?
    var sheet: Sheet?
    var failure: TeamActionFailure?
    var pendingReconfirm: TeamStoppedDevice?
    var asksRotation = false

    let team: TeamKeysTeam
    @ObservationIgnored let service: any TeamKeysCalls
    @ObservationIgnored private var allNotices: [KeyNoticeInfo] = []
    @ObservationIgnored private var changeObserver: AnyCancellable?
    // A load still out when a newer one starts lands nowhere, so a slow answer never overwrites a newer one.
    @ObservationIgnored private var generation = 0

    init(team: TeamKeysTeam, service: any TeamKeysCalls, changes: AnyPublisher<Void, Never>) {
        self.team = team
        self.service = service
        changeObserver = changes.sink { [weak self] _ in
            Task { @MainActor [weak self] in await self?.load() }
        }
    }

    var status: TeamKeyStatus? {
        snapshot.map { TeamKeysPresentation.status($0, team: team) }
    }

    var canWrapCurrentVersion: Bool {
        snapshot.map { TeamKeysPresentation.canWrapCurrentVersion($0, team: team) } ?? false
    }

    func action(for member: TeamMemberKeys) -> TeamMemberAction? {
        snapshot.flatMap { TeamKeysPresentation.action(for: member, in: $0, team: team) }
    }

    func load() async {
        generation += 1
        let current = generation
        isLoading = true
        defer {
            if current == generation { isLoading = false }
        }
        do {
            let loaded = try await service.teamKeys(team: team.id)
            guard current == generation else { return }
            snapshot = loaded
            loadFailure = nil
        } catch {
            guard current == generation else { return }
            TeamLibraryLog.failure(Self.logger, "Could not read the team keys", error)
            loadFailure = TeamKeysFailureText.message(error)
        }
        do {
            let loaded = try await service.keyNotices()
            guard current == generation else { return }
            allNotices = loaded
        } catch {
            TeamLibraryLog.failure(Self.logger, "Could not read the key notices", error)
        }
        guard current == generation else { return }
        notices = TeamKeysPresentation.notices(allNotices, team: team, snapshot: snapshot)
        do {
            let loaded = try await service.credentialsToRotate(team: team.id)
            guard current == generation else { return }
            credentials = loaded
        } catch {
            TeamLibraryLog.failure(Self.logger, "Could not read the credentials to rotate", error)
        }
    }

    func createKeys() async {
        await perform(.creating, failureTitle: String(localized: "Couldn't Create Team Keys")) { [service, team] in
            try await service.createTeamKeys(team: team.id)
        }
    }

    @discardableResult
    func confirm(_ member: TeamMemberKeys) async -> Bool {
        await perform(
            .confirming(member.account),
            failureTitle: String(format: String(localized: "Couldn't Confirm %@"), member.displayName)
        ) { [service, team] in
            try await service.confirmMember(team: team.id, account: member.account)
        }
    }

    // Accepting is this device's pin; an owner or admin then wraps the current version to the new key (0056, Teams,
    // Re-confirming).
    @discardableResult
    func acceptKeyChange(_ member: TeamMemberKeys, offeredIk: String, compared: Bool) async -> Bool {
        let reconfirms = canWrapCurrentVersion
        return await perform(
            .accepting(member.account),
            failureTitle: String(format: String(localized: "Couldn't Accept %@'s New Keys"), member.displayName)
        ) { [service, team] in
            try await service.acceptKeyChange(account: member.account, offeredIk: offeredIk, compared: compared)
            if reconfirms {
                try await service.confirmMember(team: team.id, account: member.account)
            }
        }
    }

    func rotate() async {
        await perform(.rotating, failureTitle: String(localized: "Couldn't Rotate the Team Key")) { [service, team] in
            try await service.rotateTeamKey(team: team.id, remove: [])
        }
    }

    @discardableResult
    func acceptRestart(signerIk: String) async -> Bool {
        await perform(.acceptingRestart, failureTitle: String(localized: "Couldn't Use the New Team Key")) { [service, team] in
            try await service.acceptTeamRestart(team: team.id, signerIk: signerIk)
        }
    }

    @discardableResult
    func restart(confirming accounts: [String]) async -> Bool {
        await perform(.restarting, failureTitle: String(localized: "Couldn't Start the Team Key Over")) { [service, team] in
            try await service.restartTeamKey(team: team.id, confirm: accounts)
        }
    }

    func dismiss(_ notice: TeamKeyNotice) async {
        await perform(.dismissing(notice.id), failureTitle: String(localized: "Couldn't Dismiss the Notice")) { [service] in
            try await service.dismissKeyNotice(notice: notice.id)
        }
    }

    func noticeAction(_ action: TeamKeyNoticeAction) {
        switch action {
        case .compareKeyChange(let account):
            if let member = snapshot?.member(account) {
                sheet = .keyChange(member)
            }
        case .compareRestart:
            sheet = .heldRestart
        }
    }

    // Every action reloads after it ends: a refusal such as `create_only` means the state moved on.
    @discardableResult
    private func perform(_ work: Work, failureTitle: String, _ call: @escaping () async throws -> Void) async -> Bool {
        guard self.work == nil else { return false }
        self.work = work
        defer { self.work = nil }
        var succeeded = false
        do {
            try await call()
            succeeded = true
        } catch {
            TeamLibraryLog.failure(Self.logger, "A team key action failed", error)
            if let message = TeamKeysFailureText.message(error) {
                failure = TeamActionFailure(title: failureTitle, message: message)
            }
        }
        await load()
        return succeeded
    }
}

// Who a restart wraps the new team key to (core ADR 0056, Teams, No holder left): a member only after the person said
// the words of the key this device pinned for them match, and only while that is still the key it has for them.
@MainActor @Observable
final class TeamRestartSelection {
    private(set) var words: [String: TeamFingerprintLoad] = [:]
    private(set) var compared: [String: FingerprintInfo] = [:]
    private(set) var changed: [String] = []

    @ObservationIgnored private let service: any TeamKeysCalls

    init(service: any TeamKeysCalls) {
        self.service = service
    }

    func isIncluded(_ account: String) -> Bool {
        compared[account] != nil
    }

    func loadWords(_ account: String) async {
        if case .loaded? = words[account] { return }
        words[account] = .loading
        do {
            let fingerprint = try await service.accountFingerprint(account: account)
            words[account] = .loaded(fingerprint)
        } catch {
            words[account] = .failed(TeamKeysFailureText.message(error) ?? String(localized: "Couldn't load their words."))
        }
    }

    // Only words the person saw count, so a member whose words never loaded cannot be included.
    func wordsMatch(_ account: String) {
        guard case .loaded(let fingerprint)? = words[account] else { return }
        compared[account] = fingerprint
        changed.removeAll { $0 == account }
    }

    func exclude(_ account: String) {
        compared[account] = nil
    }

    // The included accounts, in roster order, each read again first: one whose words differ from the ones compared, or
    // that no longer reads at all, is dropped and named, and nothing is returned until the person compares it again.
    func accountsToWrap(in roster: [String]) async -> [String]? {
        var accounts: [String] = []
        var moved: [String] = []
        for account in roster {
            guard let seen = compared[account] else { continue }
            let current = try? await service.accountFingerprint(account: account)
            if current == seen {
                accounts.append(account)
            } else {
                compared[account] = nil
                words[account] = nil
                moved.append(account)
            }
        }
        changed = moved
        return moved.isEmpty ? accounts : nil
    }
}
