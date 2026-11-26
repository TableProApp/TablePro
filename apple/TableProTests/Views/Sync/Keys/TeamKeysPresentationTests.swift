//
//  TeamKeysPresentationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
import Testing

@MainActor
struct TeamKeysPresentationTests {
    private typealias F = TeamKeysFixtures

    @Test("An ended team key and each stop cause outrank every other state")
    func endedAndStoppedComeFirst() {
        let owner = F.keysTeam(role: .owner)

        #expect(TeamKeysPresentation.status(F.snapshot(state: .ended, rotationDue: true), team: owner) == .ended)
        #expect(TeamKeysPresentation.status(F.snapshot(state: .stopped, stoppedCause: .restartHeld), team: owner) == .restartHeld)
        #expect(TeamKeysPresentation.status(F.snapshot(state: .stopped, stoppedCause: .restoreWait), team: owner) == .restoreWait)
        #expect(
            TeamKeysPresentation.status(F.snapshot(version: 7, state: .stopped, stoppedCause: .catchUp), team: owner)
                == .stoppedCatchUp(version: 7)
        )
        #expect(
            TeamKeysPresentation.status(F.snapshot(version: 7, state: .stopped, stoppedCause: nil), team: owner)
                == .stoppedCatchUp(version: 7)
        )
    }

    @Test("Only an owner creates a team's first keys")
    func onlyAnOwnerCreatesKeys() {
        let snapshot = F.snapshot(version: nil, holder: false)

        #expect(TeamKeysPresentation.status(snapshot, team: F.keysTeam(role: .owner)) == .noKeys(canCreate: true))
        #expect(TeamKeysPresentation.status(snapshot, team: F.keysTeam(role: .admin)) == .noKeys(canCreate: false))
    }

    @Test("With no holder on the roster only an owner is offered the restart")
    func noHolderLeftOffersTheOwnerARestart() {
        let snapshot = F.snapshot(holder: false, members: [
            F.member(F.you, isYou: true, role: .owner, status: .awaitingConfirmation),
            F.member(F.ana, status: .awaitingConfirmation),
        ])

        #expect(TeamKeysPresentation.status(snapshot, team: F.keysTeam(role: .owner)) == .noHolderLeft(canRestart: true))
        #expect(TeamKeysPresentation.status(snapshot, team: F.keysTeam(role: .admin)) == .noHolderLeft(canRestart: false))
    }

    @Test("A Mac that holds no version while a teammate does waits to be confirmed")
    func waitsForConfirmationWhileATeammateHolds() {
        let snapshot = F.snapshot(holder: false, members: [
            F.member(F.you, isYou: true, status: .awaitingConfirmation),
            F.member(F.ana, role: .owner, status: .holder),
        ])

        #expect(TeamKeysPresentation.status(snapshot, team: F.keysTeam(role: .member)) == .awaitingConfirmation)
    }

    @Test("A holder sees the version, or that a rotation is due")
    func holderStates() {
        #expect(TeamKeysPresentation.status(F.snapshot(version: 4), team: F.keysTeam(role: .member)) == .holder(version: 4))
        #expect(TeamKeysPresentation.status(F.snapshot(rotationDue: true), team: F.keysTeam(role: .member)) == .rotationDue)
    }

    @Test("Confirm is offered to an owner or admin holding the current version, never to an editor or a stopped Mac")
    func confirmNeedsAManagerHoldingTheKey() {
        let ana = F.member(F.ana, status: .awaitingConfirmation)

        #expect(TeamKeysPresentation.action(for: ana, in: F.snapshot(), team: F.keysTeam(role: .admin)) == .confirm)
        #expect(TeamKeysPresentation.action(for: ana, in: F.snapshot(), team: F.keysTeam(role: .owner)) == .confirm)
        #expect(TeamKeysPresentation.action(for: ana, in: F.snapshot(), team: F.keysTeam(role: .editor)) == nil)
        #expect(TeamKeysPresentation.action(for: ana, in: F.snapshot(holder: false), team: F.keysTeam(role: .admin)) == nil)
        #expect(
            TeamKeysPresentation.action(
                for: ana,
                in: F.snapshot(state: .stopped, stoppedCause: .catchUp),
                team: F.keysTeam(role: .admin)
            ) == nil
        )
    }

    @Test("Anyone compares a key change, and no row offers an action on this account")
    func keyChangeForEveryoneButYourself() {
        let bo = F.member(F.bo, status: .alert)
        let you = F.member(F.you, isYou: true, status: .alert)

        #expect(TeamKeysPresentation.action(for: bo, in: F.snapshot(), team: F.keysTeam(role: .member)) == .compareKeyChange)
        #expect(TeamKeysPresentation.action(for: you, in: F.snapshot(), team: F.keysTeam(role: .owner)) == nil)
        #expect(TeamKeysPresentation.action(for: F.member(F.bo, status: .holder), in: F.snapshot(), team: F.keysTeam(role: .owner)) == nil)
    }

    @Test("A restart lists the members who could take a wrap, never this account or one with no keys")
    func restartCandidates() {
        let snapshot = F.snapshot(members: [
            F.member(F.you, isYou: true, role: .owner, status: .awaitingConfirmation),
            F.member(F.ana, status: .awaitingConfirmation),
            F.member(F.bo, status: .noKeys),
        ])

        #expect(TeamKeysPresentation.restartCandidates(snapshot).map { $0.account } == [F.ana])
    }

    @Test("Notices show for this team and its members only, by name, with the action each asks for")
    func noticesForThisTeam() {
        let notices = TeamKeysPresentation.notices(
            [
                F.notice("1", .keysChanged(account: F.bo)),
                F.notice("2", .keysChanged(account: "9F9F9F9F-0000-4000-8000-000000000000")),
                F.notice("3", .restartHeld(team: F.teamID, signer: F.ana)),
                F.notice("4", .teamKeyRestarted(team: "team_other")),
                F.notice("5", .locked(cause: .deviceRemoved)),
                F.notice("6", .recoveryKeyReplaced(account: F.ana)),
                F.notice("7", .conflict(scope: F.teamID)),
            ],
            team: F.keysTeam(role: .member),
            snapshot: F.snapshot()
        )

        #expect(notices.map { $0.id } == ["1", "3", "6", "7"])
        #expect(notices[0].text.contains("Bo"))
        #expect(notices[0].action == .compareKeyChange(account: F.bo))
        #expect(notices[1].text.contains("Ana"))
        #expect(notices[1].action == .compareRestart)
        #expect(notices[3].severity == .error)
    }

    @Test("A restart by an account the roster does not name says so instead of a name")
    func restartBySomeoneOffTheRoster() {
        let notices = TeamKeysPresentation.notices(
            [F.notice("1", .restartHeld(team: F.teamID, signer: "9F9F9F9F-0000-4000-8000-000000000000"))],
            team: F.keysTeam(role: .member),
            snapshot: F.snapshot()
        )

        #expect(notices.map { $0.text } == [TeamKeysPresentation.restartHeldText(signer: nil)])
        #expect(!notices[0].text.contains("9F9F9F9F"))
    }

    @Test("A person with no name or email reads as unknown, never as an account id")
    func noRawIds() {
        let member = F.member(F.ana, status: .holder)

        #expect(member.displayName == String(localized: "Unknown person"))
        #expect(!TeamKeysPresentation.memberTitle(member).contains(F.ana))
    }

    @Test("Failures read by the server's code, a step-up the person closed shows nothing")
    func failureWords() {
        #expect(TeamKeysFailureText.message(F.rejected("create_only")) == TeamKeysFailureText.rejected("create_only"))
        #expect(TeamKeysFailureText.message(F.failure("sync.typed_back_wrong")) == TeamKeysFailureText.message(code: "sync.typed_back_wrong"))
        #expect(TeamKeysFailureText.message(F.failure("keys.kid")) == TeamKeysFailureText.message(code: "keys.signature"))
        #expect(TeamKeysFailureText.message(CoreError.Cancelled) == nil)
        #expect(TeamKeysFailureText.message(AccountError.canceled) == nil)
    }
}
