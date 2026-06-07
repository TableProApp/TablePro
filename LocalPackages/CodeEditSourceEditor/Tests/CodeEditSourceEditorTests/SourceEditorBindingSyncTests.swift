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
        coordinator.syncBindingText(bound, controller: controller)

        XCTAssertEqual(controller.textView.string, "updated")
        XCTAssertEqual(coordinator.lastSyncedText, "updated")
    }

    @MainActor
    func test_syncSkipsWhenBindingMatchesLastSyncedText() {
        var bound = "before edit"
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("in-flight user edit")

        coordinator.syncBindingText(bound, controller: controller)

        XCTAssertEqual(controller.textView.string, "in-flight user edit")
        XCTAssertEqual(coordinator.lastSyncedText, "before edit")
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
        XCTAssertEqual(coordinator.lastSyncedText, "typed text")
        XCTAssertTrue(coordinator.isUpdateFromTextView)
    }

    @MainActor
    func test_editNotificationDuringProgrammaticSyncDoesNotWriteBack() {
        var bound = "external"
        var setterCallCount = 0
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0; setterCallCount += 1 })
        controller.textView.setText("stale")
        coordinator.isUpdatingFromRepresentable = true

        coordinator.textViewDidChangeText(
            Notification(name: TextView.textDidChangeNotification, object: controller.textView)
        )

        XCTAssertEqual(setterCallCount, 0)
        XCTAssertFalse(coordinator.isUpdateFromTextView)
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
        XCTAssertTrue(coordinator.isUpdateFromTextView)

        coordinator.syncBindingText(bound, controller: controller)
        XCTAssertEqual(controller.textView.string, largeText)

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(bound, largeText)
        XCTAssertEqual(coordinator.lastSyncedText, largeText)
    }

    @MainActor
    func test_syncShorterTextDropsOutOfBoundsSelection() {
        var bound = "select * from table"
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("select * from table")
        controller.textView.selectionManager.setSelectedRange(NSRange(location: 19, length: 0))

        bound = "ab"
        coordinator.syncBindingText(bound, controller: controller)

        XCTAssertEqual(controller.textView.string, "ab")
        for selection in controller.textView.selectionManager.textSelections {
            XCTAssertLessThanOrEqual(selection.range.max, 2)
        }
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
        XCTAssertTrue(coordinator.isUpdateFromTextView)

        coordinator.syncBindingText("", controller: controller)

        XCTAssertEqual(controller.textView.string, "s")
        XCTAssertEqual(coordinator.lastSyncedText, "s")
    }

    @MainActor
    func test_syncAppliesExternalChangeAfterEditFlagIsCleared() {
        var bound = ""
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("select 1")

        coordinator.textViewDidChangeText(
            Notification(name: TextView.textDidChangeNotification, object: controller.textView)
        )
        coordinator.isUpdateFromTextView = false

        bound = "SELECT 1"
        coordinator.syncBindingText(bound, controller: controller)

        XCTAssertEqual(controller.textView.string, "SELECT 1")
        XCTAssertEqual(coordinator.lastSyncedText, "SELECT 1")
    }

    @MainActor
    func test_repeatedSyncWithSameValueLeavesTextViewUntouched() {
        var bound = "stable"
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("stable")
        let storageBefore = controller.textView.textStorage

        coordinator.syncBindingText(bound, controller: controller)

        XCTAssertIdentical(controller.textView.textStorage, storageBefore)
        XCTAssertEqual(controller.textView.string, "stable")
    }
}
