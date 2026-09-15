//
//  SourceEditorDismantleTests.swift
//  TableProEditorKitTests
//
//  `onDisappear` fires on a live editor whenever its pane is unparented, so teardown hangs off
//  `dismantleNSViewController`, which fires only when the representable's identity goes. A coordinator
//  destroyed twice, or left in the list, is what that contract exists to prevent (#2236).
//

import AppKit
import SwiftUI
@testable import TableProEditorKit
import Testing

private final class RecordingCoordinator: TextViewCoordinator {
    private(set) var destroyCount = 0

    func prepareCoordinator(controller: TextViewController) {}

    func destroy() {
        destroyCount += 1
    }
}

@MainActor
@Suite("SourceEditor dismantle")
struct SourceEditorDismantleTests {
    @Test("dismantleNSViewController destroys each text coordinator once and empties the list")
    func dismantleDestroysCoordinatorsOnce() {
        let recording = RecordingCoordinator()
        let controller = Mock.loadedTextViewController(string: "SELECT 1", coordinators: [recording])
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
}
