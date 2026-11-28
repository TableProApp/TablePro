import Foundation
@testable import TablePro
import TableProFFI
import Testing

struct SyncMoveKeysStepTests {
    @Test("Each key state the move meets asks for its own step, and held keys ask for none")
    func stepForEachKeyState() {
        #expect(SyncMoveKeysStep.step(for: .approved(av: 2, keyDevice: "D")) == nil)
        #expect(SyncMoveKeysStep.step(for: .noKeys) == .setUpRecoveryKey)
        #expect(SyncMoveKeysStep.step(for: .needsApproval(request: "R1")) == .approveThisMac(request: "R1"))
        #expect(SyncMoveKeysStep.step(for: .needsApproval(request: nil)) == .approveThisMac(request: nil))
        #expect(SyncMoveKeysStep.step(for: .locked(cause: .deviceRemoved)) == .openEncryptionSettings)
        #expect(SyncMoveKeysStep.step(for: .noDeviceStore) == .checkAgain)
        #expect(SyncMoveKeysStep.step(for: .unknown) == .checkAgain)
    }

    @Test("A recovery key set up moves at once, another device's keys ask for approval next, and a cancel stays")
    func afterRecoveryKeySetup() {
        #expect(SyncMoveKeysNext.after(AccountRecoveryKeySetupResult.done) == .move)
        #expect(SyncMoveKeysNext.after(AccountRecoveryKeySetupResult.approvalNeeded) == .present(.approveThisMac(request: nil)))
        #expect(SyncMoveKeysNext.after(AccountRecoveryKeySetupResult.cancelled) == .stay)
    }

    @Test("An approved Mac moves at once, and a cancelled approval stays")
    func afterApproval() {
        #expect(SyncMoveKeysNext.after(AccountDeviceApprovalResult.approved) == .move)
        #expect(SyncMoveKeysNext.after(AccountDeviceApprovalResult.cancelled) == .stay)
    }

    @Test("A step's identity changes with the request it opens")
    func identities() {
        #expect(SyncMoveKeysStep.approveThisMac(request: "A").id != SyncMoveKeysStep.approveThisMac(request: "B").id)
        #expect(SyncMoveKeysStep.setUpRecoveryKey.id != SyncMoveKeysStep.checkAgain.id)
    }
}
