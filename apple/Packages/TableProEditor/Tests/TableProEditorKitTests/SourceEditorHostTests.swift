//
//  SourceEditorHostTests.swift
//  TableProEditorKitTests
//
//  An AppKit container gets the editor with the same two-way sync SwiftUI gives it. A state write the editor makes
//  latches its change; under SwiftUI the write's update pass consumes the latch, and here the host has to.
//

import AppKit
import SwiftUI
@testable import TableProEditorKit
import Testing

@MainActor
private final class Owner {
    var text: String
    var reportedStates: [SourceEditorState] = []
    let coordinator: RecordingCoordinator

    init(text: String, coordinator: RecordingCoordinator = RecordingCoordinator()) {
        self.text = text
        self.coordinator = coordinator
    }

    var textBinding: Binding<String> {
        Binding(get: { self.text }, set: { self.text = $0 })
    }

    func editor(_ state: Binding<SourceEditorState>) -> SourceEditor {
        SourceEditor(
            textBinding,
            language: .default,
            configuration: Mock.config(),
            state: state,
            highlightProviders: [],
            coordinators: [coordinator]
        )
    }
}

private final class RecordingCoordinator: TextViewCoordinator {
    private(set) var destroyCount = 0

    func prepareCoordinator(controller: TextViewController) {}

    func destroy() {
        destroyCount += 1
    }
}

@MainActor
struct SourceEditorHostTests {
    private func mount(_ owner: Owner) -> (SourceEditorHost, NSWindow) {
        let host = SourceEditorHost { owner.editor($0) }
        host.onStateChange = { _, new in owner.reportedStates.append(new) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host.controller.view
        window.contentView?.layoutSubtreeIfNeeded()
        return (host, window)
    }

    @Test("The owner's text reaches the editor, and an edit reaches the owner")
    func textSyncsBothWays() {
        let owner = Owner(text: "SELECT 1")
        let (host, window) = mount(owner)
        defer { window.orderOut(nil) }
        #expect(host.controller.textView.string == "SELECT 1")

        owner.text = "SELECT 2"
        host.update { owner.editor($0) }
        #expect(host.controller.textView.string == "SELECT 2")

        host.controller.textView.replaceCharacters(in: NSRange(location: 8, length: 0), with: "0")
        #expect(owner.text == "SELECT 20")
    }

    @Test("A caret the editor reports is passed on and does not swallow the owner's next text")
    func stateWriteKeepsTheNextTextPush() {
        let owner = Owner(text: "SELECT 1")
        let (host, window) = mount(owner)
        defer { window.orderOut(nil) }

        let caret = NSRange(location: 3, length: 0)
        host.controller.setCursorPositions([CursorPosition(range: caret)])
        let held = host.state.cursorPositions?.map { $0.range }
        let reported = owner.reportedStates.last?.cursorPositions?.map { $0.range }
        #expect(held == [caret])
        #expect(reported == [caret])

        owner.text = "SELECT 42"
        host.update { owner.editor($0) }
        #expect(host.controller.textView.string == "SELECT 42")
    }

    @Test("dismantle destroys each text coordinator once")
    func dismantleDestroysCoordinatorsOnce() {
        let owner = Owner(text: "SELECT 1")
        let (host, window) = mount(owner)
        defer { window.orderOut(nil) }

        host.dismantle()

        #expect(owner.coordinator.destroyCount == 1)
        #expect(host.controller.textCoordinators.values().isEmpty)
    }
}
