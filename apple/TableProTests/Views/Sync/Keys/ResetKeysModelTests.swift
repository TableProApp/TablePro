//
//  ResetKeysModelTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProFFI
import TableProTestSupport
import Testing

@MainActor
struct ResetKeysModelTests {
    private typealias R = ResetKeysFixtures
    private typealias F = TeamKeysFixtures

    private final class StepUps {
        var challenges: [StepUpChallenge] = []
        var answer: (any Error)?
        var gate: AsyncGate?
    }

    private let service = FakeResetKeysService()
    private let stepUps = StepUps()
    private let changes = PassthroughSubject<Void, Never>()

    private var stepUp: StepUpRetry {
        StepUpRetry { [stepUps] challenge in
            stepUps.challenges.append(challenge)
            await stepUps.gate?.wait()
            if let answer = stepUps.answer { throw answer }
        }
    }

    private func model(now: Date = R.held.addingTimeInterval(-3600)) -> ResetKeysModel {
        ResetKeysModel(service: service, stepUp: stepUp, changes: changes.eraseToAnyPublisher(), now: { now })
    }

    private func proposal(_ kind: ResetKindTag = .startEmpty) -> ResetProposalModel {
        ResetProposalModel(kind: kind, service: service, stepUp: stepUp)
    }

    private static let stepUpRequired = F.failure(
        "sync.step_up_required",
        sync: .stepUp(acrValues: ["urn:tablepro:acr:passkey"], maxAgeSecs: 300)
    )

    @Test("An approved Mac offers the reset that keeps the keys, any other a reset that starts empty")
    func offeredKindFollowsTheKeyState() async {
        let model = model()

        await model.load()
        #expect(model.offeredKind == .keepScopeKeys)
        #expect(model.cancelsWithoutRecoveryKey)

        service.update { $0.keyState = .needsApproval(request: nil) }
        await model.load()
        #expect(model.offeredKind == .startEmpty)
        #expect(!model.cancelsWithoutRecoveryKey)

        service.update { $0.keyState = .locked(cause: .deviceRemoved) }
        await model.load()
        #expect(model.offeredKind == .startEmpty)

        service.update { $0.keyState = .noKeys }
        await model.load()
        #expect(model.offeredKind == nil)
    }

    @Test("Only a pending reset shows as pending, and the reset notices come from the key notices")
    func loadsPendingAndNotices() async {
        service.update { state in
            state.pending = R.pending(state: .cancelled)
            state.notices = [
                F.notice("n1", .resetEnded(reset: "reset-0", state: .superseded)),
                F.notice("n2", .keysChanged(account: F.ana)),
                F.notice("n3", .resetWaitsForStepUp(reset: "reset-1")),
            ]
        }
        let model = model()

        await model.load()

        #expect(model.pending == nil)
        #expect(model.notices == [
            ResetNotice(id: "n1", kind: .ended(.superseded)),
            ResetNotice(id: "n3", kind: .waitsForStepUp(reset: "reset-1")),
        ])
    }

    @Test("Only the proposing Mac finishes, and only once the wait has passed")
    func activationWaitsForTheHold() {
        let before = model(now: R.held.addingTimeInterval(-1))
        let after = model(now: R.held)

        #expect(!before.canActivate(R.pending()))
        #expect(after.canActivate(R.pending()))
        #expect(!after.canActivate(R.pending(mine: false)))
        #expect(!after.canActivate(R.pending(state: .cancelled)))
    }

    @Test("A certified Mac cancels without the recovery key, another Mac with it")
    func cancelsBothWays() async {
        let model = model()

        await model.cancel(R.pending(mine: false))
        let cancelled = await model.cancel(R.pending(mine: false), recoveryKey: R.recoveryKey)

        #expect(cancelled)
        #expect(service.calls == [
            .cancel(reset: "reset-1", recoveryKey: nil),
            .cancel(reset: "reset-1", recoveryKey: R.recoveryKey),
        ])
    }

    @Test("A lost kind 3 proposal goes up again behind the step-up the server asks for")
    func proposesAgainAfterAStepUp() async {
        service.update { $0.failures["proposeResetAgain"] = [Self.stepUpRequired] }
        let model = model()

        await model.proposeAgain("reset-1")

        #expect(stepUps.challenges.count == 1)
        #expect(service.calls == [.proposeAgain(reset: "reset-1"), .proposeAgain(reset: "reset-1")])
        #expect(model.failure == nil)
    }

    @Test("A wait not over yet is refused with its own words")
    func activationTooEarly() async {
        service.update { $0.failures["activateReset"] = [F.rejected("reset_held")] }
        let model = model()

        await model.activate(R.pending())

        #expect(model.failure?.message == TeamKeysFailureText.rejected("reset_held"))
    }

    @Test("The new recovery key shows in its 14 groups, and the groups to type back count from 1")
    func showsTheKeyThenAsksForTwoGroups() async {
        let proposal = proposal(.keepScopeKeys)

        await proposal.begin()

        #expect(proposal.phase == .showKey)
        #expect(proposal.groups.count == 14)
        #expect(proposal.groups.first == "0123")
        #expect(proposal.checkedGroups == [3, 12])
        #expect(service.calls == [.begin(.keepScopeKeys)])

        proposal.continueToTypeBack()
        #expect(proposal.phase == .typeBack)
        #expect(!proposal.canSubmit)
    }

    @Test("Typing back sends the groups with the draft, and the proposal ends pending")
    func submitsTheTypedGroups() async {
        let proposal = proposal(.keepScopeKeys)
        await proposal.begin()
        proposal.continueToTypeBack()
        proposal.typed = ["89AB", "MNPQ"]

        await proposal.submit()

        #expect(proposal.phase == .done)
        #expect(proposal.proposed == R.pending())
        #expect(proposal.draft == nil)
        #expect(service.calls.last == .finish(draft: "draft-1", typed: ["89AB", "MNPQ"]))
        #expect(stepUps.challenges.isEmpty)
    }

    @Test("Groups typed back wrong keep the person on that step with the reason")
    func wrongGroupsStay() async {
        service.update { $0.failures["finishResetProposal"] = [F.failure("sync.typed_back_wrong")] }
        let proposal = proposal()
        await proposal.begin()
        proposal.continueToTypeBack()
        proposal.typed = ["AAAA", "BBBB"]

        await proposal.submit()

        #expect(proposal.phase == .typeBack)
        #expect(proposal.failure == TeamKeysFailureText.message(code: "sync.typed_back_wrong"))
    }

    @Test("A kind 3 proposal the server challenges steps up once and is sent again")
    func startEmptyStepsUp() async {
        service.update { $0.failures["finishResetProposal"] = [Self.stepUpRequired] }
        let proposal = proposal(.startEmpty)
        await proposal.begin()
        proposal.continueToTypeBack()
        proposal.typed = ["89AB", "MNPQ"]

        await proposal.submit()

        #expect(stepUps.challenges == [StepUpChallenge(acrValues: ["urn:tablepro:acr:passkey"], maxAgeSecs: 300)])
        #expect(proposal.phase == .done)
        #expect(service.calls.filter { if case .finish = $0 { true } else { false } }.count == 2)
    }

    @Test("A sheet closed before the proposal went up discards its draft once, and one that finished discards nothing")
    func closingDiscardsTheDraft() async {
        let closed = proposal(.keepScopeKeys)
        await closed.begin()
        await closed.close()
        await closed.close()

        let finished = proposal(.keepScopeKeys)
        await finished.begin()
        finished.continueToTypeBack()
        finished.typed = ["89AB", "MNPQ"]
        await finished.submit()
        await finished.close()

        let discards = service.calls.filter { if case .discard = $0 { true } else { false } }
        #expect(discards == [.discard(draft: "draft-1")])
        #expect(closed.draft == nil)
        #expect(closed.groups.isEmpty)
    }

    @Test("A draft that arrives after the sheet closed is discarded as it lands")
    func lateDraftIsDiscarded() async {
        let stepUpOpen = AsyncGate()
        stepUps.gate = stepUpOpen
        service.update { $0.failures["beginReset"] = [Self.stepUpRequired] }
        let proposal = proposal(.startEmpty)

        let preparing = Task { await proposal.begin() }
        try? await waitUntil { stepUps.challenges.count == 1 }
        await proposal.close()
        await stepUpOpen.open()
        await preparing.value

        #expect(proposal.draft == nil)
        #expect(proposal.phase == .preparing)
        #expect(service.calls.last == .discard(draft: "draft-1"))
    }

    @Test("Closing the passkey page leaves the proposal on its step with no error")
    func closedStepUpShowsNothing() async {
        service.update { $0.failures["finishResetProposal"] = [Self.stepUpRequired] }
        stepUps.answer = AccountError.canceled
        let proposal = proposal(.startEmpty)
        await proposal.begin()
        proposal.continueToTypeBack()
        proposal.typed = ["89AB", "MNPQ"]

        await proposal.submit()

        #expect(proposal.phase == .typeBack)
        #expect(proposal.failure == nil)
    }
}
