import AppKit
import SwiftUI
import Testing

@testable import TableProEditorKit
import TableProTextEngine

@MainActor
final class SourceEditorBindingSyncTests {
    var controller: TextViewController!

    init() throws {
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
            highlightProviders: nil,
            textCoordinators: []
        )
    }

    @MainActor
    @Test func test_externalBindingChangeUpdatesTextView() {
        var bound = "initial"
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("initial")

        bound = "updated"
        coordinator.textSync.applyRepresentableText(bound, controller: controller)

        #expect(controller.textView.string == "updated")
        #expect(coordinator.textSync.lastSyncedText == "updated")
    }

    @MainActor
    @Test func test_syncSkipsWhenBindingMatchesLastSyncedText() {
        var bound = "before edit"
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("in-flight user edit")

        coordinator.textSync.applyRepresentableText(bound, controller: controller)

        #expect(controller.textView.string == "in-flight user edit")
        #expect(coordinator.textSync.lastSyncedText == "before edit")
    }

    @MainActor
    @Test func test_textViewEditWritesBackAndRecordsLastSyncedText() {
        var bound = ""
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("typed text")

        coordinator.textViewDidChangeText(
            Notification(name: TextView.textDidChangeNotification, object: controller.textView)
        )

        #expect(bound == "typed text")
        #expect(coordinator.textSync.lastSyncedText == "typed text")
        #expect(coordinator.phase.isEditorChangePending)
    }

    @MainActor
    @Test func test_editNotificationDuringProgrammaticSyncDoesNotWriteBack() {
        var bound = "external"
        var setterCallCount = 0
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0; setterCallCount += 1 })
        controller.textView.setText("stale")

        coordinator.phase.applyRepresentableValue {
            coordinator.textViewDidChangeText(
                Notification(name: TextView.textDidChangeNotification, object: controller.textView)
            )
        }

        #expect(setterCallCount == 0)
        #expect(!coordinator.phase.isEditorChangePending)
        #expect(bound == "external")
    }

    @MainActor
    @Test func test_largeDocumentEditDebouncesWritebackWithoutClobbering() async throws {
        var bound = ""
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        let largeText = String(repeating: "a", count: 500_001)
        controller.textView.setText(largeText)

        coordinator.textViewDidChangeText(
            Notification(name: TextView.textDidChangeNotification, object: controller.textView)
        )

        #expect(bound == "")
        #expect(coordinator.phase.isEditorChangePending)

        coordinator.textSync.applyRepresentableText(bound, controller: controller)
        #expect(controller.textView.string == largeText)

        await coordinator.textSync.writebackTask?.value
        #expect(bound == largeText)
        #expect(coordinator.textSync.lastSyncedText == largeText)
    }

    @MainActor
    @Test func test_syncSkipsStaleBindingSnapshotWhileEditIsInFlight() {
        var bound = ""
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("s")

        coordinator.textViewDidChangeText(
            Notification(name: TextView.textDidChangeNotification, object: controller.textView)
        )
        #expect(bound == "s")
        #expect(coordinator.phase.isEditorChangePending)

        coordinator.textSync.applyRepresentableText("", controller: controller)

        #expect(controller.textView.string == "s")
        #expect(coordinator.textSync.lastSyncedText == "s")
    }

    @MainActor
    @Test func test_syncAppliesExternalChangeAfterEditFlagIsCleared() {
        var bound = ""
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("select 1")

        coordinator.textViewDidChangeText(
            Notification(name: TextView.textDidChangeNotification, object: controller.textView)
        )
        coordinator.phase.consumePendingEditorChange()

        bound = "SELECT 1"
        coordinator.textSync.applyRepresentableText(bound, controller: controller)

        #expect(controller.textView.string == "SELECT 1")
        #expect(coordinator.textSync.lastSyncedText == "SELECT 1")
    }

    @MainActor
    @Test func test_syncRebuildsHighlighterForReplacementStorage() {
        var bound = "select * from users"
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("select * from users")
        controller.setUpHighlighter()
        let highlighterBefore = controller.highlighter
        #expect(highlighterBefore != nil)

        bound = "SELECT\n    *\nFROM\n    users"
        coordinator.textSync.applyRepresentableText(bound, controller: controller)

        #expect(controller.textView.string == "SELECT\n    *\nFROM\n    users")
        #expect(controller.highlighter != nil)
        #expect(controller.highlighter !== highlighterBefore)
    }

    @MainActor
    @Test func test_syncQueriesHighlightsForReplacementStorage() {
        let provider = HighlighterTests.MockHighlightProvider()
        let providerController = TextViewController(
            string: "select * from users",
            language: .sql,
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

        #expect(provider.setUpCount > setUpsBefore)
        #expect(provider.queryCount > queriesBefore)
    }

    @MainActor
    @Test func test_syncShorterTextDropsOutOfBoundsSelection() {
        var bound = "select * from table"
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("select * from table")
        controller.textView.selectionManager.setSelectedRange(NSRange(location: 19, length: 0))

        bound = "ab"
        coordinator.textSync.applyRepresentableText(bound, controller: controller)

        #expect(controller.textView.string == "ab")
        for selection in controller.textView.selectionManager.textSelections {
            #expect(selection.range.max <= 2)
        }
    }

    @MainActor
    @Test func test_repeatedSyncWithSameValueLeavesTextViewUntouched() {
        var bound = "stable"
        let coordinator = makeCoordinator(get: { bound }, set: { bound = $0 })
        controller.textView.setText("stable")
        let storageBefore = controller.textView.textStorage

        coordinator.textSync.applyRepresentableText(bound, controller: controller)

        #expect(controller.textView.textStorage === storageBefore)
        #expect(controller.textView.string == "stable")
    }
}
