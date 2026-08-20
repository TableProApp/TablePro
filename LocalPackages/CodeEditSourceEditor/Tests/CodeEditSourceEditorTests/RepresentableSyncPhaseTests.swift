import XCTest

@testable import CodeEditSourceEditor

final class RepresentableSyncPhaseTests: XCTestCase {
    @MainActor
    func test_startsIdle() {
        let phase = RepresentableSyncPhase()

        XCTAssertEqual(phase.phase, .idle)
        XCTAssertFalse(phase.isEditorChangePending)
        XCTAssertFalse(phase.isApplyingRepresentableValue)
    }

    @MainActor
    func test_markEditorChangeLatchesUntilConsumed() {
        let phase = RepresentableSyncPhase()

        phase.markEditorChange()
        phase.markEditorChange()

        XCTAssertTrue(phase.isEditorChangePending)
        XCTAssertTrue(phase.consumePendingEditorChange())
        XCTAssertEqual(phase.phase, .idle)
    }

    @MainActor
    func test_consumeWithoutPendingChangeReturnsFalse() {
        let phase = RepresentableSyncPhase()

        XCTAssertFalse(phase.consumePendingEditorChange())
        XCTAssertEqual(phase.phase, .idle)
    }

    @MainActor
    func test_markDuringRepresentableApplicationIsIgnored() {
        let phase = RepresentableSyncPhase()

        phase.applyRepresentableValue {
            phase.markEditorChange()
            XCTAssertTrue(phase.isApplyingRepresentableValue)
        }

        XCTAssertEqual(phase.phase, .idle)
        XCTAssertFalse(phase.isEditorChangePending)
    }

    @MainActor
    func test_applyRepresentableValueRestoresPriorPhase() {
        let phase = RepresentableSyncPhase()
        phase.markEditorChange()

        phase.applyRepresentableValue {
            XCTAssertTrue(phase.isApplyingRepresentableValue)
        }

        XCTAssertTrue(phase.isEditorChangePending)
    }
}
