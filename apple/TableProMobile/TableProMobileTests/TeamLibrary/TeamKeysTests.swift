import Combine
import Foundation
import TableProFFI
@testable import TableProMobile
import Testing

private let owner = TeamKeysTeam(id: "team_a", name: "Analytics", role: .owner)
private let member = TeamKeysTeam(id: "team_a", name: "Analytics", role: .member)

private func person(_ account: String, status: MemberKeyStatusTag, isYou: Bool = false) -> TeamMemberKeys {
    TeamMemberKeys(account: account, name: account.capitalized, email: nil, isYou: isYou, role: .member, status: status)
}

private func snapshot(
    version: UInt32? = 3,
    state: KeyVersionStateTag = .ok,
    cause: StopCauseTag? = nil,
    rotationDue: Bool = false,
    holder: Bool = true,
    members: [TeamMemberKeys] = []
) -> TeamKeysSnapshot {
    TeamKeysSnapshot(
        version: version,
        state: state,
        stoppedCause: cause,
        rotationDue: rotationDue,
        holder: holder,
        members: members,
        stoppedDevices: []
    )
}

@MainActor
struct TeamKeysTests {
    @Test("An ended or stopped key says so before anything else about it")
    func stoppedComesFirst() {
        #expect(TeamKeysPresentation.status(snapshot(state: .ended, rotationDue: true), team: owner) == .ended)
        #expect(TeamKeysPresentation.status(snapshot(state: .stopped, cause: .restartHeld), team: owner) == .restartHeld)
        #expect(TeamKeysPresentation.status(snapshot(state: .stopped, cause: nil), team: owner) == .stoppedCatchUp(version: 3))
    }

    @Test("Only an owner creates keys or starts them over, and only while no one holds the key")
    func ownerOnlyActions() {
        #expect(TeamKeysPresentation.status(snapshot(version: nil), team: owner) == .noKeys(canCreate: true))
        #expect(TeamKeysPresentation.status(snapshot(version: nil), team: member) == .noKeys(canCreate: false))
        let noHolder = snapshot(holder: false, members: [person("bea", status: .awaitingConfirmation)])
        #expect(TeamKeysPresentation.status(noHolder, team: owner) == .noHolderLeft(canRestart: true))
        let someoneHolds = snapshot(holder: false, members: [person("bea", status: .holder)])
        #expect(TeamKeysPresentation.status(someoneHolds, team: member) == .awaitingConfirmation)
        #expect(TeamKeysPresentation.status(snapshot(rotationDue: true), team: member) == .rotationDue)
        #expect(TeamKeysPresentation.status(snapshot(), team: member) == .holder(version: 3))
    }

    @Test("A member waiting for confirmation is confirmed only by a holder who manages keys, and never yourself")
    func memberActions() {
        let waiting = person("bea", status: .awaitingConfirmation)
        let changed = person("cy", status: .alert)
        let you = person("ana", status: .alert, isYou: true)
        let held = snapshot(members: [waiting, changed, you])

        #expect(TeamKeysPresentation.action(for: waiting, in: held, team: owner) == .confirm)
        #expect(TeamKeysPresentation.action(for: waiting, in: held, team: member) == nil)
        #expect(TeamKeysPresentation.action(for: waiting, in: snapshot(holder: false, members: [waiting]), team: owner) == nil)
        #expect(TeamKeysPresentation.action(for: changed, in: held, team: member) == .compareKeyChange)
        #expect(TeamKeysPresentation.action(for: you, in: held, team: owner) == nil)
    }

    @Test("A restart lists those who could take the key, and holds back a member whose keys changed")
    func restartCandidates() {
        let roster = snapshot(members: [
            person("ana", status: .holder, isYou: true),
            person("bea", status: .awaitingConfirmation),
            person("cy", status: .alert),
            person("dee", status: .noKeys),
        ])

        #expect(TeamKeysPresentation.restartCandidates(roster).map(\.account) == ["bea"])
        #expect(TeamKeysPresentation.restartWaitsForKeyChange(roster).map(\.account) == ["cy"])
    }

    @Test("Notices name members this team knows, and another team's notice stays off this page")
    func notices() {
        let roster = snapshot(members: [person("bea", status: .alert)])
        let notices = [
            KeyNoticeInfo(id: "n1", kind: .keysChanged(account: "bea")),
            KeyNoticeInfo(id: "n2", kind: .keysChanged(account: "stranger")),
            KeyNoticeInfo(id: "n3", kind: .teamKeyRestarted(team: "team_b")),
            KeyNoticeInfo(id: "n4", kind: .restartHeld(team: "team_a", signer: "bea")),
        ]

        let shown = TeamKeysPresentation.notices(notices, team: owner, snapshot: roster)

        #expect(shown.map(\.id) == ["n1", "n4"])
        #expect(shown.first?.action == .compareKeyChange(account: "bea"))
        #expect(shown.last?.action == .compareRestart)
    }

    @Test("A refusal the server sends by code, and a missing key service, read as their own words")
    func failureWords() {
        let rejected = FakeTeamLibraryCalls.failure("sync.rejected", sync: .rejected(code: "role"))

        #expect(TeamKeysFailureText.message(rejected) == String(localized: "Your role on this team doesn't allow this."))
        #expect(TeamKeysFailureText.message(KeyServiceUnavailable()) == String(localized: "Sign in to your TablePro account to use end-to-end keys."))
        #expect(TeamKeysFailureText.message(CancellationError()) == nil)
        #expect(TeamKeysFailureText.message(code: "keys.something_new") == String(localized: "The keys the server sent didn't check out, so nothing changed."))
    }

    @Test("Confirming a member wraps the key to them and reads the team again; a refusal shows its words")
    func confirmAndFailure() async {
        let calls = FakeTeamLibraryCalls()
        let bea = person("bea", status: .awaitingConfirmation)
        calls.update { $0.keys = snapshot(members: [bea]) }
        let model = TeamKeysModel(team: owner, service: calls, changes: Empty().eraseToAnyPublisher())
        await model.load()

        #expect(await model.confirm(bea))
        #expect(calls.read { $0.confirmed } == ["bea"])

        calls.fail("confirmMember", with: FakeTeamLibraryCalls.failure("sync.rejected", sync: .rejected(code: "key_dependency")))
        #expect(await model.confirm(bea) == false)
        #expect(model.failure?.message == String(localized: "This person hasn't shared their keys with the team yet. Try again later."))
    }

    @Test("A restart wraps only to members whose words still match the ones compared")
    func restartSelection() async {
        let calls = FakeTeamLibraryCalls()
        calls.update { $0.fingerprints = ["bea": FingerprintInfo(words: ["alpha"], qr: "TPF1:A"), "cy": FingerprintInfo(words: ["gamma"], qr: "TPF1:C")] }
        let selection = TeamRestartSelection(service: calls)
        await selection.loadWords("bea")
        await selection.loadWords("cy")
        selection.wordsMatch("bea")
        selection.wordsMatch("cy")

        #expect(await selection.accountsToWrap(in: ["bea", "cy"]) == ["bea", "cy"])

        calls.update { $0.fingerprints["cy"] = FingerprintInfo(words: ["changed"], qr: "TPF1:X") }
        #expect(await selection.accountsToWrap(in: ["bea", "cy"]) == nil)
        #expect(selection.changed == ["cy"])
        #expect(!selection.isIncluded("cy"))
        #expect(selection.isIncluded("bea"))
    }

    @Test("Words that never loaded can't be marked as matching")
    func unloadedWordsDontCount() {
        let selection = TeamRestartSelection(service: FakeTeamLibraryCalls())

        selection.wordsMatch("bea")

        #expect(!selection.isIncluded("bea"))
    }
}
