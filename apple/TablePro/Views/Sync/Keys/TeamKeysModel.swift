//
//  TeamKeysModel.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProFFI

internal enum TeamCodeComparison: Equatable {
    case matches
    case differs
    case unreadable
}

// One team's keys page: the team key's state, its members' keys, the devices stopped on it and what a removed party
// could read (core ADR 0056, Pins and Teams).
@MainActor
internal final class TeamKeysModel: ObservableObject {
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

    @Published private(set) var snapshot: TeamKeysSnapshot?
    @Published private(set) var notices: [TeamKeyNotice] = []
    @Published private(set) var credentials: [TeamCredentialToRotate] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailure: String?
    @Published private(set) var work: Work?
    @Published var sheet: Sheet?
    @Published var failure: AccountActionFailure?
    @Published var pendingReconfirm: TeamStoppedDevice?
    @Published var asksRotation = false

    let team: TeamKeysTeam
    let service: any TeamKeysService
    private var allNotices: [KeyNoticeInfo] = []
    private var changeObserver: AnyCancellable?
    // A load still out when a newer one starts lands nowhere, so a slow answer never overwrites a newer one.
    private var generation = 0

    init(team: TeamKeysTeam, service: any TeamKeysService, changes: AnyPublisher<Void, Never>) {
        self.team = team
        self.service = service
        changeObserver = changes.sink { [weak self] _ in
            guard let self else { return }
            Task { await self.load() }
        }
    }

    convenience init(team: TeamKeysTeam) {
        self.init(
            team: team,
            service: TeamKeysLiveService.shared,
            changes: SyncEngineHost.shared.keyChanges.eraseToAnyPublisher()
        )
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
            loadFailure = TeamKeysFailureText.message(error)
        }
        do {
            let loaded = try await service.keyNotices()
            guard current == generation else { return }
            allNotices = loaded
        } catch {
            Self.logger.error("Could not read the key notices: \(error.publicLogShape, privacy: .public)")
        }
        guard current == generation else { return }
        notices = TeamKeysPresentation.notices(allNotices, team: team, snapshot: snapshot)
        do {
            let loaded = try await service.credentialsToRotate(team: team.id)
            guard current == generation else { return }
            credentials = loaded
        } catch {
            Self.logger.error("Could not read the credentials to rotate: \(error.publicLogShape, privacy: .public)")
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

    // Accepting is this Mac's pin; an owner or admin then wraps the current version to the new key (0056, Teams,
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

    func compareCode(_ text: String, with member: TeamMemberKeys) async -> TeamCodeComparison {
        do {
            return try await service.compareFingerprintQr(account: member.account, text: text) ? .matches : .differs
        } catch {
            if case .Failed(let info)? = error as? CoreError, info.code == "keys.encoding" {
                return .unreadable
            }
            failure = AccountActionFailure(
                title: String(localized: "Couldn't Check the Code"),
                message: TeamKeysFailureText.message(error) ?? ""
            )
            return .unreadable
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
            if let message = TeamKeysFailureText.message(error) {
                failure = AccountActionFailure(title: failureTitle, message: message)
            }
        }
        await load()
        return succeeded
    }
}
