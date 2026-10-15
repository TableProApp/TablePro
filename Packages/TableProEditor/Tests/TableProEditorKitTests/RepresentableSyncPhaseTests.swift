import Foundation
import Testing

@testable import TableProEditorKit

@MainActor
struct RepresentableSyncPhaseTests {
    @MainActor
    @Test func test_startsIdle() {
        let phase = RepresentableSyncPhase()

        #expect(phase.phase == .idle)
        #expect(!phase.isEditorChangePending)
        #expect(!phase.isApplyingRepresentableValue)
    }

    @MainActor
    @Test func test_markEditorChangeLatchesUntilConsumed() {
        let phase = RepresentableSyncPhase()

        phase.markEditorChange()
        phase.markEditorChange()

        #expect(phase.isEditorChangePending)
        #expect(phase.consumePendingEditorChange())
        #expect(phase.phase == .idle)
    }

    @MainActor
    @Test func test_consumeWithoutPendingChangeReturnsFalse() {
        let phase = RepresentableSyncPhase()

        #expect(!phase.consumePendingEditorChange())
        #expect(phase.phase == .idle)
    }

    @MainActor
    @Test func test_markDuringRepresentableApplicationIsIgnored() {
        let phase = RepresentableSyncPhase()

        phase.applyRepresentableValue {
            phase.markEditorChange()
            #expect(phase.isApplyingRepresentableValue)
        }

        #expect(phase.phase == .idle)
        #expect(!phase.isEditorChangePending)
    }

    @MainActor
    @Test func test_applyRepresentableValueRestoresPriorPhase() {
        let phase = RepresentableSyncPhase()
        phase.markEditorChange()

        phase.applyRepresentableValue {
            #expect(phase.isApplyingRepresentableValue)
        }

        #expect(phase.isEditorChangePending)
    }
}
