import Foundation
@testable import TableProMobile
import Testing

@MainActor
@Suite("Connection restore decision")
struct ConnectionRestoreDecisionTests {
    private let storedId = UUID()

    @Test("A held restore presents nothing and keeps the stored id")
    func heldRestorePresentsNothing() {
        let decision = ConnectionRestoreDecision.resolve(storedId: storedId, isHeld: true)

        #expect(decision == .hold)
        #expect(decision.presentedId == nil)
    }

    @Test("Releasing the hold presents the stored connection")
    func releasedRestorePresents() {
        let decision = ConnectionRestoreDecision.resolve(storedId: storedId, isHeld: false)

        #expect(decision == .present(storedId))
        #expect(decision.presentedId == storedId)
    }

    @Test("Nothing stored is nothing to restore, held or not")
    func nothingStored() {
        #expect(ConnectionRestoreDecision.resolve(storedId: nil, isHeld: true) == .nothing)
        #expect(ConnectionRestoreDecision.resolve(storedId: nil, isHeld: false) == .nothing)
    }

    @Test("A locked launch holds the restore, and the unlock delivers it")
    func lockedLaunchHoldsThenDelivers() {
        let presenter = ScenePresenter(isLocked: true)

        #expect(ConnectionRestoreDecision.resolve(
            storedId: storedId,
            isHeld: presenter.holdsConnectionRestore
        ) == .hold)

        presenter.lockDidChange(false)

        #expect(ConnectionRestoreDecision.resolve(
            storedId: storedId,
            isHeld: presenter.holdsConnectionRestore
        ) == .present(storedId))
    }
}
