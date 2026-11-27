import AppKit
import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

// The close button used to close the window through willClose alone, dropping staged edits with no question.
@Suite("Connection window close question", .serialized)
@MainActor
struct ConnectionWindowCloseQuestionTests {
    private static let size = CGSize(width: 1_200, height: 800)

    @Test("A window holding no work closes at once")
    func closesWithNoWork() throws {
        let window = try ClosingWindow()
        defer { window.tearDown() }

        #expect(window.fixture.controller.windowShouldClose(window.fixture.window))
        #expect(window.prompts.count == 0)
    }

    @Test("Staged work asks first, and Cancel keeps the window")
    func stagedWorkAsksAndCancelKeepsTheWindow() async throws {
        let window = try ClosingWindow()
        defer { window.tearDown() }
        window.coordinator.toolbarState.hasCreateTablePending = true

        #expect(!window.fixture.controller.windowShouldClose(window.fixture.window))

        try await waitUntil { window.fixture.controller.pendingCloseAnswer == nil }
        #expect(window.prompts.count == 1)
        #expect(window.fixture.window.isVisible)
    }

    @Test("A cell still in its editor lands before the window is read")
    func openCellEditCommitsFirst() throws {
        let window = try ClosingWindow()
        defer { window.tearDown() }
        let tab = QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users")
        window.coordinator.tabManager.tabs.append(tab)
        window.coordinator.tabManager.selectedTabId = tab.id
        let editor = CommittingCellEditor { window.coordinator.toolbarState.hasCreateTablePending = true }
        window.coordinator.gridModel(forTab: tab.id).attach(editor)

        #expect(!window.fixture.controller.windowShouldClose(window.fixture.window))
        #expect(editor.commits == 1)
    }

    @Test("A second click while the first question is open asks nothing more")
    func secondClickWhilePendingAsksNothing() async throws {
        let window = try ClosingWindow()
        defer { window.tearDown() }
        window.coordinator.toolbarState.hasCreateTablePending = true
        let gate = AsyncGate()
        window.actions.confirmSaveChanges = { [prompts = window.prompts] _, _ in
            prompts.count += 1
            await gate.wait()
            return .cancel
        }

        #expect(!window.fixture.controller.windowShouldClose(window.fixture.window))
        try await waitUntil { window.prompts.count == 1 }
        #expect(!window.fixture.controller.windowShouldClose(window.fixture.window))
        await gate.open()
        try await waitUntil { window.fixture.controller.pendingCloseAnswer == nil }

        #expect(window.prompts.count == 1)
        #expect(window.fixture.window.isVisible)
    }

    // Agent mode while still connecting mounts no browse content, so the window has no command actions.
    @Test("A window with no browse content still asks before stopping an agent reply")
    func windowWithoutActionsAsksAboutRunningWork() async throws {
        let fixture = try OffscreenConnectionWindow(size: Self.size)
        defer { fixture.tearDown() }
        fixture.window.orderFront(nil)
        var stopped = 0
        let reply = RunningWork(
            kind: .agentReply,
            subject: "Shipping report",
            connectionName: "Agent window",
            connectionIds: [fixture.workspace.connectionId],
            cancel: { stopped += 1 }
        )
        fixture.controller.runningWork = { scope in scope.contains(reply) ? [reply] : [] }
        var answers = [false, true]
        let prompts = PromptLog()
        fixture.controller.confirmStoppingWork = { _, _ in
            prompts.count += 1
            return answers.removeFirst()
        }
        try #require(fixture.split.closeQuestionActions == nil)

        #expect(!fixture.controller.windowShouldClose(fixture.window))
        try await waitUntil { fixture.controller.pendingCloseAnswer == nil }
        #expect(fixture.window.isVisible, "Cancel must keep the window and the reply")
        #expect(stopped == 0)

        #expect(!fixture.controller.windowShouldClose(fixture.window))
        try await waitUntil { fixture.controller.pendingCloseAnswer == nil }
        #expect(prompts.count == 2)
        #expect(stopped == 1)
        #expect(!fixture.window.isVisible)
    }

    @Test("Option-click on a close button closes every window; a plain click or a key does not")
    func optionClickClosesEveryWindow() throws {
        let optionUp = try Self.click(.leftMouseUp, modifiers: .option)
        let optionDown = try Self.click(.leftMouseDown, modifiers: .option)
        let plain = try Self.click(.leftMouseUp, modifiers: [])
        #expect(WindowCloseReview.closesEveryWindow(optionUp))
        #expect(WindowCloseReview.closesEveryWindow(optionDown))
        #expect(!WindowCloseReview.closesEveryWindow(plain))
        let key = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        ))
        #expect(!WindowCloseReview.closesEveryWindow(key))
        #expect(!WindowCloseReview.closesEveryWindow(nil))
    }

    @Test("Windows asked during one Option-click answer one Review Changes alert")
    func oneEventAsksOnce() async throws {
        let first = try ClosingWindow(name: "Review first")
        let second = try ClosingWindow(name: "Review second")
        defer {
            first.tearDown()
            second.tearDown()
        }
        let review = WindowCloseReview()
        let asked = AlertLog()
        review.ask = { count, _, _ in
            asked.windowCounts.append(count)
            return .cancel
        }
        let event = try Self.click(.leftMouseUp, modifiers: .option)

        let firstAnswer = review.enlist(first.actions, window: first.fixture.window, for: event)
        let secondAnswer = review.enlist(second.actions, window: second.fixture.window, for: event)
        await firstAnswer.value
        await secondAnswer.value

        #expect(firstAnswer == secondAnswer)
        #expect(asked.windowCounts == [2])
        #expect(first.prompts.count == 0 && second.prompts.count == 0)
        #expect(first.fixture.window.isVisible && second.fixture.window.isVisible)
    }

    @Test("Discard Changes closes every window it asked about without asking each")
    func discardClosesEveryWindow() async throws {
        let first = try ClosingWindow(name: "Discard first")
        let second = try ClosingWindow(name: "Discard second")
        defer {
            first.tearDown()
            second.tearDown()
        }
        first.coordinator.toolbarState.hasCreateTablePending = true
        second.coordinator.toolbarState.hasCreateTablePending = true
        let review = WindowCloseReview()
        review.ask = { _, _, _ in .discard }

        await review.review([first.entry, second.entry])

        #expect(!first.fixture.window.isVisible && !second.fixture.window.isVisible)
        #expect(first.prompts.count == 0 && second.prompts.count == 0)
    }

    @Test("Review Changes asks each window in turn and stops at the first Cancel")
    func reviewStopsAtTheFirstCancel() async throws {
        let first = try ClosingWindow(name: "Review cancel first")
        let second = try ClosingWindow(name: "Review cancel second")
        defer {
            first.tearDown()
            second.tearDown()
        }
        first.coordinator.toolbarState.hasCreateTablePending = true
        second.coordinator.toolbarState.hasCreateTablePending = true
        let review = WindowCloseReview()
        review.ask = { _, _, _ in .review }

        await review.review([first.entry, second.entry])

        #expect(first.prompts.count == 1)
        #expect(second.prompts.count == 0)
        #expect(first.fixture.window.isVisible && second.fixture.window.isVisible)
    }

    @Test("A window another close took while an earlier question was up is skipped, not asked")
    func reviewSkipsAWindowClosedMeanwhile() async throws {
        let first = try ClosingWindow(name: "Review closed first")
        let second = try ClosingWindow(name: "Review closed second")
        defer {
            first.tearDown()
            second.tearDown()
        }
        first.coordinator.toolbarState.hasCreateTablePending = true
        second.coordinator.toolbarState.hasCreateTablePending = true
        first.actions.confirmSaveChanges = { [prompts = first.prompts] _, _ in
            prompts.count += 1
            second.fixture.window.close()
            return .dontSave
        }
        let review = WindowCloseReview()
        review.ask = { _, _, _ in .review }

        await review.review([first.entry, second.entry])

        #expect(first.prompts.count == 1)
        #expect(second.prompts.count == 0)
        #expect(!first.fixture.window.isVisible && !second.fixture.window.isVisible)
    }

    @Test("One window with work gets its own question, not the Review Changes alert")
    func oneWindowGetsItsOwnQuestion() async throws {
        let only = try ClosingWindow(name: "Review only")
        defer { only.tearDown() }
        only.coordinator.toolbarState.hasCreateTablePending = true
        let review = WindowCloseReview()
        let asked = AlertLog()
        review.ask = { count, _, _ in
            asked.windowCounts.append(count)
            return .discard
        }

        await review.review([only.entry])

        #expect(asked.windowCounts.isEmpty)
        #expect(only.prompts.count == 1)
    }

    private static func click(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}

@MainActor
private final class PromptLog {
    var count = 0
}

@MainActor
private final class AlertLog {
    var windowCounts: [Int] = []
}

// A real connection window whose save question is answered Cancel, so no alert reaches the run.
@MainActor
private struct ClosingWindow {
    let fixture: OffscreenConnectionWindow
    let coordinator: MainContentCoordinator
    let actions: MainContentCommandActions
    let prompts = PromptLog()

    init(name: String = "Close question") throws {
        fixture = try OffscreenConnectionWindow(
            size: CGSize(width: 1_200, height: 800),
            connectedTo: TestFixtures.makeConnection(name: name, type: .mysql)
        )
        fixture.window.orderFront(nil)
        let coordinator = try #require(fixture.workspace.sessionState?.coordinator)
        let deadline = Date(timeIntervalSinceNow: 2)
        while coordinator.commandActions == nil, Date() < deadline {
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        self.coordinator = coordinator
        actions = try #require(coordinator.commandActions)
        coordinator.contentWindow = fixture.window
        actions.window = fixture.window
        actions.runningWork = { _ in [] }
        actions.confirmSaveChanges = { [prompts] _, _ in
            prompts.count += 1
            return .cancel
        }
    }

    var entry: WindowCloseReview.Entry {
        WindowCloseReview.Entry(actions: actions, window: fixture.window)
    }

    func tearDown() {
        coordinator.toolbarState.hasCreateTablePending = false
        fixture.window.orderOut(nil)
        fixture.tearDown()
    }
}

// Stands in for a grid whose cell is still in its field editor: committing is what stages the edit.
@MainActor
private final class CommittingCellEditor: DataGridMountedView {
    private let onCommit: () -> Void
    private(set) var commits = 0

    init(onCommit: @escaping () -> Void) {
        self.onCommit = onCommit
    }

    func apply(_ change: DataGridChange) {}
    func selectionDidChange() {}
    func configurationDidChange() {}
    func reveal(row: Int, displayColumn: Int?) {}
    func revealColumn(_ displayColumn: Int) {}
    func sortDidChange() {}
    func summaryRulesDidChange() {}
    func viewportSample() -> (row: Int, offset: CGFloat)? { nil }
    func beginEditing(row: Int, displayColumn: Int) -> Bool { false }
    var isEditing: Bool { commits == 0 }
    func commitEditing() -> Bool {
        commits += 1
        onCommit()
        return true
    }
    func discardEditing() {}
    func focus() -> Bool { false }
    func anchor(forColumn displayColumn: Int) -> (view: NSView, rect: NSRect)? { nil }
}
