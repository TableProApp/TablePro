//
//  TeamKeysModelTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProFFI
import TableProTestSupport
import Testing

@MainActor
struct TeamKeysModelTests {
    private typealias F = TeamKeysFixtures

    private let service = FakeTeamKeysService()
    private let changes = PassthroughSubject<Void, Never>()

    private func model(role: TeamRoleTag? = .admin) -> TeamKeysModel {
        TeamKeysModel(team: F.keysTeam(role: role), service: service, changes: changes.eraseToAnyPublisher())
    }

    @Test("A load shows the team key, this team's notices and the credentials to rotate")
    func loadsEverything() async {
        let credential = TeamCredentialToRotate(envelope: "library_connection/c1/password", connectionName: "Prod", secret: .password)
        service.update { state in
            state.notices = [F.notice("n1", .keysChanged(account: F.bo)), F.notice("n2", .teamKeyRestarted(team: "team_other"))]
            state.credentials = [credential]
        }
        let model = model()

        await model.load()

        #expect(model.snapshot == F.snapshot())
        #expect(model.status == .holder(version: 3))
        #expect(model.notices.map { $0.id } == ["n1"])
        #expect(model.credentials == [credential])
        #expect(model.loadFailure == nil)
    }

    @Test("A failed refresh keeps what was loaded and says why")
    func failedRefreshKeepsTheSnapshot() async {
        let model = model()
        await model.load()
        service.update { $0.failures["teamKeys"] = F.failure("sync.network") }

        await model.load()

        #expect(model.snapshot == F.snapshot())
        #expect(model.loadFailure == TeamKeysFailureText.message(code: "sync.network"))
    }

    @Test("Confirming wraps to that member and reloads")
    func confirmsAndReloads() async {
        let model = model()
        await model.load()
        let ana = F.member(F.ana, name: "Ana", role: .editor, status: .awaitingConfirmation)
        let loads = service.read { $0.loads }

        let confirmed = await model.confirm(ana)

        #expect(confirmed)
        #expect(service.calls == [.confirm(team: F.teamID, account: F.ana)])
        #expect(service.read { $0.loads } == loads + 1)
        #expect(model.work == nil)
    }

    @Test("A confirmation another admin made first says so and still reloads")
    func confirmationRaceReloads() async {
        service.update { $0.failures["confirmMember"] = F.rejected("create_only") }
        let model = model()
        await model.load()
        let loads = service.read { $0.loads }

        let confirmed = await model.confirm(F.member(F.ana, name: "Ana", status: .awaitingConfirmation))

        #expect(!confirmed)
        #expect(model.failure?.message == TeamKeysFailureText.rejected("create_only"))
        #expect(service.read { $0.loads } == loads + 1)
    }

    @Test("An admin holding the key accepts a key change, then wraps the current version to the new key")
    func adminReconfirmsAfterAccepting() async {
        let model = model(role: .admin)
        await model.load()
        let bo = F.member(F.bo, name: "Bo", status: .alert)

        await model.acceptKeyChange(bo, offeredIk: "new-ik", compared: true)

        #expect(service.calls == [
            .accept(account: F.bo, offeredIk: "new-ik", compared: true),
            .confirm(team: F.teamID, account: F.bo),
        ])
    }

    @Test("A member accepts a key change for this Mac's pin only, recorded as compared or not")
    func memberOnlyAccepts() async {
        let model = model(role: .member)
        await model.load()
        let bo = F.member(F.bo, name: "Bo", status: .alert)

        await model.acceptKeyChange(bo, offeredIk: "new-ik", compared: false)

        #expect(service.calls == [.accept(account: F.bo, offeredIk: "new-ik", compared: false)])
    }

    @Test("A scanned code matches, differs, or does not parse")
    func comparesCodes() async {
        service.update { $0.matchingCodes[F.ana] = F.qr }
        let model = model()
        let ana = F.member(F.ana, status: .awaitingConfirmation)

        #expect(await model.compareCode(F.qr, with: ana) == .matches)
        #expect(await model.compareCode("TPF1:OTHER", with: ana) == .differs)
        service.update { $0.failures["compareFingerprintQr"] = F.failure("keys.encoding") }
        #expect(await model.compareCode("not a code", with: ana) == .unreadable)
        #expect(model.failure == nil)
    }

    @Test("A held restart is accepted for the signer's key the person compared")
    func acceptsTheComparedRestart() async {
        let model = model()

        let accepted = await model.acceptRestart(signerIk: "signer-ik")

        #expect(accepted)
        #expect(service.calls == [.acceptRestart(team: F.teamID, signerIk: "signer-ik")])
    }

    @Test("A restart wraps to the members the owner included, and a rotation removes no one")
    func restartAndRotate() async {
        let model = model(role: .owner)

        await model.restart(confirming: [F.ana])
        await model.rotate()

        #expect(service.calls == [
            .restart(team: F.teamID, confirm: [F.ana]),
            .rotate(team: F.teamID, remove: []),
        ])
    }

    @Test("A notice's action opens the sheet it asks for")
    func noticeActionsOpenSheets() async {
        let model = model()
        await model.load()

        model.noticeAction(.compareKeyChange(account: F.bo))
        #expect(model.sheet == .keyChange(F.member(F.bo, name: "Bo", status: .alert)))

        model.noticeAction(.compareRestart)
        #expect(model.sheet == .heldRestart)
    }

    @Test("Dismissing a notice removes it")
    func dismissesNotices() async throws {
        service.update { $0.notices = [F.notice("n1", .keysChanged(account: F.bo))] }
        let model = model()
        await model.load()
        let notice = try #require(model.notices.first)

        await model.dismiss(notice)

        #expect(service.calls == [.dismiss(notice: "n1")])
        #expect(model.notices.isEmpty)
    }

    @Test("A key change signal from the engine reloads the page")
    func keyChangesReload() async throws {
        let model = model()
        await model.load()
        service.update { $0.snapshot = F.snapshot(version: 4) }

        changes.send()

        try await waitUntil { model.snapshot?.version == 4 }
    }
}
