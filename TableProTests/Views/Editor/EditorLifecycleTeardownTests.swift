//
//  EditorLifecycleTeardownTests.swift
//  TableProTests
//
//  Regression tests for #2236. A connection switch unparents the outgoing connection's pane
//  and re-parents it on the way back, which SwiftUI reports as onDisappear then onAppear on a
//  live editor. Teardown wired to that pair blanked the SQL editor, cleared its undo stack, and
//  left its highlighter and key bindings dead, because only loadView() rebuilds them.
//

import AppKit
@testable import CodeEditSourceEditor
import CodeEditTextView
import SwiftUI
@testable import TablePro
import Testing

private final class RecordingCoordinator: TextViewCoordinator {
    private(set) var destroyCount = 0

    func prepareCoordinator(controller: TextViewController) {}

    func destroy() {
        destroyCount += 1
    }
}

private final class DismantleRecorder {
    var makeCount = 0
    var dismantleCount = 0
}

private struct DismantleProbe: NSViewControllerRepresentable {
    let recorder: DismantleRecorder

    func makeNSViewController(context: Context) -> NSViewController {
        recorder.makeCount += 1
        let controller = NSViewController()
        controller.view = NSView()
        return controller
    }

    func updateNSViewController(_ controller: NSViewController, context: Context) {}

    static func dismantleNSViewController(_ controller: NSViewController, coordinator: DismantleRecorder) {
        coordinator.dismantleCount += 1
    }

    func makeCoordinator() -> DismantleRecorder {
        recorder
    }
}

@MainActor
@Suite("Editor lifecycle teardown")
struct EditorLifecycleTeardownTests {
    @Test("releaseHeavyState keeps the document")
    func releaseHeavyStateKeepsDocument() {
        let controller = EditorControllerFixture.make(string: "SELECT * FROM users WHERE id = 1")

        controller.releaseHeavyState()

        #expect(controller.textView.string == "SELECT * FROM users WHERE id = 1")
    }

    @Test("releaseHeavyState keeps the undo stack")
    func releaseHeavyStateKeepsUndoStack() {
        let controller = EditorControllerFixture.make(string: "SELECT 1")
        controller.textView.replaceCharacters(in: NSRange(location: 8, length: 0), with: " -- note")
        #expect(controller.textView._undoManager?.canUndo == true)

        controller.releaseHeavyState()

        #expect(controller.textView._undoManager?.canUndo == true)
    }

    @Test("SQLEditorCoordinator.destroy keeps the document")
    func coordinatorDestroyKeepsDocument() {
        let coordinator = SQLEditorCoordinator()
        let controller = EditorControllerFixture.make(string: "SELECT 1", coordinators: [coordinator])

        coordinator.destroy()

        #expect(controller.textView.string == "SELECT 1")
    }

    @Test("dismantleNSViewController destroys each text coordinator once and empties the list")
    func dismantleDestroysCoordinatorsOnce() {
        let recording = RecordingCoordinator()
        let controller = EditorControllerFixture.make(string: "SELECT 1", coordinators: [recording])
        let coordinator = SourceEditor.Coordinator(
            text: .binding(.constant("SELECT 1")),
            editorState: .constant(SourceEditorState()),
            highlightProviders: [],
            textCoordinators: [recording]
        )

        SourceEditor.dismantleNSViewController(controller, coordinator: coordinator)

        #expect(recording.destroyCount == 1)
        #expect(controller.textCoordinators.values().isEmpty)
    }

    /// The production shape: closing a connection removes it from the registry, which selects a
    /// neighbour and unparents this pane, so `teardown()` always runs on a detached hosting
    /// controller. Nothing lays a detached view out, so without the explicit layout pass SwiftUI
    /// never reconciles the cleared `rootView` and the tree stays mounted.
    @Test("WorkspacePanes.teardown dismantles a detached pane's content")
    func teardownDismantlesDetachedPaneContent() throws {
        let recorder = DismantleRecorder()
        let panes = WorkspacePanes()
        let window = try mount(panes.detail, showing: DismantleProbe(recorder: recorder))
        defer { window.orderOut(nil) }

        panes.detail.view.removeFromSuperview()
        #expect(recorder.dismantleCount == 0)

        panes.teardown()

        #expect(recorder.dismantleCount == 1)
        #expect(panes.detail.parent == nil)
    }

    @Test("WorkspacePanes.teardown dismantles a pane that is still on screen")
    func teardownDismantlesAttachedPaneContent() throws {
        let recorder = DismantleRecorder()
        let panes = WorkspacePanes()
        let window = try mount(panes.detail, showing: DismantleProbe(recorder: recorder))
        defer { window.orderOut(nil) }

        panes.teardown()

        #expect(recorder.dismantleCount == 1)
        #expect(panes.detail.view.superview == nil)
        #expect(panes.detail.parent == nil)
    }

    /// Returns the window so the caller keeps it alive for the length of the test. `NSWindow`
    /// defaults `isReleasedWhenClosed` to true, so closing one that ARC also owns over-releases it
    /// and takes the whole test host down with it; the window is ordered out instead. A probe that
    /// never builds fails the test rather than letting it pass having asserted nothing.
    private func mount(_ pane: NSHostingController<AnyView>, showing probe: DismantleProbe) throws -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = container

        pane.rootView = AnyView(probe)
        pane.view.frame = container.bounds
        container.addSubview(pane.view)

        let deadline = Date(timeIntervalSinceNow: 10)
        while probe.recorder.makeCount == 0, Date() < deadline {
            pane.view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        try #require(probe.recorder.makeCount == 1, "the probe never mounted, so the test proves nothing")
        return window
    }
}
