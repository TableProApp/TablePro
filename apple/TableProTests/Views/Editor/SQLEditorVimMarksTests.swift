// Typed, pasted and undone text never passes through the Vim engine, so the editor reports each edit to it.

import AppKit
import TableProEditorKit
import TableProTestSupport
import TableProTextEngine
import Testing

@testable import TablePro

extension GlobalStateSuites {
    @Suite(.appSettings { $0.editor.keyBindings = .vim })
    @MainActor
    struct SQLEditorVimMarksTests {
        @Test("A line typed above a mark moves it down, and undoing the line moves it back")
        func marksFollowEditsMadeInTheEditor() throws {
            let coordinator = SQLEditorCoordinator(diagnosticsClock: ManualClock())
            coordinator.databaseType = .mysql
            let controller = EditorControllerFixture.make(string: "SELECT 1;\nSELECT 2;\n", coordinators: [coordinator])
            defer { coordinator.destroy() }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = controller.view
            defer { window.orderOut(nil) }
            let textView = try #require(controller.textView)

            var marks = VimDocumentMarks()
            marks.marks["a"] = 13
            coordinator.restoreVimDocumentMarks(marks)

            textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "-- note\n")
            #expect(coordinator.vimDocumentMarks?.marks["a"] == 21)

            textView.undoManager?.undo()
            #expect(textView.string == "SELECT 1;\nSELECT 2;\n")
            #expect(coordinator.vimDocumentMarks?.marks["a"] == 13)
        }
    }
}
