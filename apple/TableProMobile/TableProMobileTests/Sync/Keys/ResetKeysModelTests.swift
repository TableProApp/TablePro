import Combine
import Foundation
import TableProFFI
@testable import TableProMobile
import TableProTestSupport
import Testing

@MainActor
struct ResetKeysModelTests {
    private static let held = Date(timeIntervalSince1970: 1_800_000_000)

    private static func model(_ fixture: AccountKeysFixture) -> ResetKeysModel {
        ResetKeysModel(environment: fixture.environment)
    }

    @Test("An approved device offers the reset that keeps the keys, any other one a reset that starts empty")
    func offeredKind() async {
        let fixture = AccountKeysFixture()
        let model = Self.model(fixture)

        await model.load()
        #expect(model.offeredKind == .keepScopeKeys)
        #expect(model.cancelsWithoutRecoveryKey)

        fixture.resets.update { $0.keyState = .needsApproval(request: nil) }
        await model.load()
        #expect(model.offeredKind == .startEmpty)
        #expect(!model.cancelsWithoutRecoveryKey)

        fixture.resets.update { $0.keyState = .noKeys }
        await model.load()
        #expect(model.offeredKind == nil)
    }

    @Test("Only the proposing device finishes, and only once the wait has passed")
    func activationWaitsForTheHold() {
        let fixture = AccountKeysFixture()
        let model = Self.model(fixture)
        let mine = FakeResetKeysService.pending(mine: true, heldUntil: Self.held)
        let theirs = FakeResetKeysService.pending(mine: false, heldUntil: Self.held)

        fixture.now = Self.held.addingTimeInterval(-60)
        #expect(!model.canActivate(mine))
        fixture.now = Self.held
        #expect(model.canActivate(mine))
        #expect(!model.canActivate(theirs))
    }

    @Test("Only a pending reset shows as pending, and the reset notices come from the key notices")
    func pendingAndNotices() async {
        let fixture = AccountKeysFixture()
        fixture.resets.update {
            $0.pending = FakeResetKeysService.pending(mine: false, heldUntil: Self.held)
            $0.notices = [
                KeyNoticeInfo(id: "n1", kind: .resetEnded(reset: "reset-0", state: .cancelled)),
                KeyNoticeInfo(id: "n2", kind: .deviceRemoved(device: "kd-2")),
                KeyNoticeInfo(id: "n3", kind: .resetWaitsForStepUp(reset: "reset-2")),
            ]
        }
        let model = Self.model(fixture)

        await model.load()

        #expect(model.pending?.reset == "reset-1")
        #expect(model.notices.map(\.id) == ["n1", "n3"])
        #expect(model.notices.last?.tone == .warning)
    }

    @Test("A certified device cancels without the recovery key, and the work ends with the call")
    func certifiedDeviceCancels() async {
        let fixture = AccountKeysFixture()
        fixture.resets.update { $0.pending = FakeResetKeysService.pending(mine: true, heldUntil: Self.held) }
        let model = Self.model(fixture)
        await model.load()

        guard let pending = model.pending else {
            Issue.record("The pending reset must load")
            return
        }
        await model.cancel(pending)

        #expect(fixture.resets.read { $0.calls } == ["cancelReset"])
        #expect(model.work == nil)
    }

    @Test("A proposal shows the new key in 14 groups, types back two counted from 1, and ends pending")
    func proposalRunsToPending() async {
        let fixture = AccountKeysFixture()
        let proposal = ResetProposalModel(kind: .keepScopeKeys, service: fixture.resets, stepUp: fixture.environment.stepUp)

        await proposal.begin()
        #expect(proposal.phase == .showKey)
        #expect(proposal.groups.count == 14)
        #expect(proposal.checkedGroups == [3, 12])
        proposal.continueToTypeBack()
        #expect(!proposal.canSubmit)
        proposal.typed = ["0021", "0084"]
        await proposal.submit()

        #expect(proposal.phase == .done)
        #expect(proposal.proposed?.mine == true)
        #expect(proposal.groups.isEmpty)
        await proposal.close()
        #expect(fixture.resets.read { $0.calls } == ["beginReset", "finishResetProposal"])
    }

    @Test("A sheet closed before the proposal went up discards its draft")
    func closedProposalDiscards() async {
        let fixture = AccountKeysFixture()
        let proposal = ResetProposalModel(kind: .startEmpty, service: fixture.resets, stepUp: fixture.environment.stepUp)
        await proposal.begin()

        await proposal.close()

        #expect(fixture.resets.read { $0.calls } == ["beginReset", "discardKeyDraft"])
        #expect(proposal.groups.isEmpty)
    }

    @Test("A proposal that fails after its sheet closed discards its draft, since nothing tries it again")
    func closedDuringSubmitDiscardsOnFailure() async throws {
        let fixture = AccountKeysFixture()
        let gate = AsyncGate()
        fixture.resets.update {
            $0.proposalGate = gate
            $0.proposalFailure = FakeAccountKeyFlows.failure("sync.network")
        }
        let proposal = ResetProposalModel(kind: .keepScopeKeys, service: fixture.resets, stepUp: fixture.environment.stepUp)
        await proposal.begin()
        proposal.continueToTypeBack()
        proposal.typed = ["0021", "0084"]

        let submitting = Task { await proposal.submit() }
        await gate.arrived(1)
        await proposal.close()
        #expect(fixture.resets.read { $0.calls } == ["beginReset", "finishResetProposal"])
        await gate.open()
        await submitting.value

        #expect(fixture.resets.read { $0.calls } == ["beginReset", "finishResetProposal", "discardKeyDraft"])
        #expect(proposal.groups.isEmpty)
    }
}
