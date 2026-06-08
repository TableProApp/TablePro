import AppKit
import SwiftUI
import XCTest

@testable import CodeEditSourceEditor
import CodeEditTextView

final class SourceEditorBindingSyncTests: XCTestCase {
    var controller: TextViewController!

    override func setUpWithError() throws {
        controller = Mock.textViewController(theme: Mock.theme())
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        controller.view.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func makeCoordinator(
        get: @escaping () -> String,
        set: @escaping (String) -> Void
    ) -> SourceEditor.Coordinator {
        SourceEditor.Coordinator(
            text: .binding(Binding(get: get, set: { set($0) })),
            editorState: .constant(SourceEditorState()),
            highlightProviders: nil
        )
    }

    @MainActor
    func test_externalBindingChangeUpdatesTextView() {
        var bound = "initial"
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("initial")

        bound = "updated"
        coordinator.textSync.applyRepresentableText(bound, controller: controller)

        XCTAssertEqual(controller.textView.string, "updated")
        XCTAssertEqual(coordinator.textSync.lastSyncedText, "updated")
    }

    @MainActor
    func test_syncSkipsWhenBindingMatchesLastSyncedText() {
        var bound = "before edit"
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("in-flight user edit")

        coordinator.textSync.applyRepresentableText(bound, controller: controller)

        XCTAssertEqual(controller.textView.string, "in-flight user edit")
        XCTAssertEqual(coordinator.textSync.lastSyncedText, "before edit")
    }

    @MainActor
    func test_textViewEditWritesBackAndRecordsLastSyncedText() {
        var bound = ""
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("typed text")

        coordinator.textViewDidChangeText(
            Notification(name: TextView.textDidChangeNotification, object: controller.textView)
        )

        XCTAssertEqual(bound, "typed text")
        XCTAssertEqual(coordinator.textSync.lastSyncedText, "typed text")
        XCTAssertTrue(coordinator.phase.isEditorChangePending)
    }

    @MainActor
    func test_editNotificationDuringProgrammaticSyncDoesNotWriteBack() {
        var bound = "external"
        var setterCallCount = 0
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0; setterCallCount += 1 })
        controller.textView.setText("stale")

        coordinator.phase.applyRepresentableValue {
            coordinator.textViewDidChangeText(
                Notification(name: TextView.textDidChangeNotification, object: controller.textView)
            )
        }

        XCTAssertEqual(setterCallCount, 0)
        XCTAssertFalse(coordinator.phase.isEditorChangePending)
        XCTAssertEqual(bound, "external")
    }

    @MainActor
    func test_largeDocumentEditDebouncesWritebackWithoutClobbering() async throws {
        var bound = ""
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        let largeText = String(repeating: "a", count: 500_001)
        controller.textView.setText(largeText)

        coordinator.textViewDidChangeText(
            Notification(name: TextView.textDidChangeNotification, object: controller.textView)
        )

        XCTAssertEqual(bound, "")
        XCTAssertTrue(coordinator.phase.isEditorChangePending)

        coordinator.textSync.applyRepresentableText(bound, controller: controller)
        XCTAssertEqual(controller.textView.string, largeText)

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(bound, largeText)
        XCTAssertEqual(coordinator.textSync.lastSyncedText, largeText)
    }

    @MainActor
    func test_syncSkipsStaleBindingSnapshotWhileEditIsInFlight() {
        var bound = ""
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("s")

        coordinator.textViewDidChangeText(
            Notification(name: TextView.textDidChangeNotification, object: controller.textView)
        )
        XCTAssertEqual(bound, "s")
        XCTAssertTrue(coordinator.phase.isEditorChangePending)

        coordinator.textSync.applyRepresentableText("", controller: controller)

        XCTAssertEqual(controller.textView.string, "s")
        XCTAssertEqual(coordinator.textSync.lastSyncedText, "s")
    }

    @MainActor
    func test_syncAppliesExternalChangeAfterEditFlagIsCleared() {
        var bound = ""
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("select 1")

        coordinator.textViewDidChangeText(
            Notification(name: TextView.textDidChangeNotification, object: controller.textView)
        )
        coordinator.phase.consumePendingEditorChange()

        bound = "SELECT 1"
        coordinator.textSync.applyRepresentableText(bound, controller: controller)

        XCTAssertEqual(controller.textView.string, "SELECT 1")
        XCTAssertEqual(coordinator.textSync.lastSyncedText, "SELECT 1")
    }

    @MainActor
    func test_syncRebuildsHighlighterForReplacementStorage() {
        var bound = "select * from users"
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("select * from users")
        controller.setUpHighlighter()
        let highlighterBefore = controller.highlighter
        XCTAssertNotNil(highlighterBefore)

        bound = "SELECT\n    *\nFROM\n    users"
        coordinator.textSync.applyRepresentableText(bound, controller: controller)

        XCTAssertEqual(controller.textView.string, "SELECT\n    *\nFROM\n    users")
        XCTAssertNotNil(controller.highlighter)
        XCTAssertNotIdentical(controller.highlighter, highlighterBefore)
    }

    @MainActor
    func test_syncQueriesHighlightsForReplacementStorage() {
        let provider = HighlighterTests.MockHighlightProvider()
        let providerController = TextViewController(
            string: "select * from users",
            language: .html,
            configuration: Mock.config(),
            cursorPositions: [],
            highlightProviders: [provider]
        )
        providerController.loadView()
        providerController.view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        providerController.view.layoutSubtreeIfNeeded()

        let setUpsBefore = provider.setUpCount
        let queriesBefore = provider.queryCount

        var bound = "select * from users"
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        bound = "SELECT\n    *\nFROM\n    users"
        coordinator.textSync.applyRepresentableText(bound, controller: providerController)

        XCTAssertGreaterThan(provider.setUpCount, setUpsBefore)
        XCTAssertGreaterThan(provider.queryCount, queriesBefore)
    }

    @MainActor
    func test_syncShorterTextDropsOutOfBoundsSelection() {
        var bound = "select * from table"
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("select * from table")
        controller.textView.selectionManager.setSelectedRange(NSRange(location: 19, length: 0))

        bound = "ab"
        coordinator.textSync.applyRepresentableText(bound, controller: controller)

        XCTAssertEqual(controller.textView.string, "ab")
        for selection in controller.textView.selectionManager.textSelections {
            XCTAssertLessThanOrEqual(selection.range.max, 2)
        }
    }

    @MainActor
    func test_repeatedSyncWithSameValueLeavesTextViewUntouched() {
        var bound = "stable"
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("stable")
        let storageBefore = controller.textView.textStorage

        coordinator.textSync.applyRepresentableText(bound, controller: controller)

        XCTAssertIdentical(controller.textView.textStorage, storageBefore)
        XCTAssertEqual(controller.textView.string, "stable")
    }
}
