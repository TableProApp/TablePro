//
//  RecentTabSwitcherControllerTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
private final class RecordingPresenter: RecentTabSwitcherPresenting {
    private(set) var presented: RecentTabSwitcherModel?
    private(set) var dismissCount = 0
    private(set) var onClose: (() -> Void)?

    func presentRecentTabSwitcher(_ model: RecentTabSwitcherModel, over window: NSWindow?, onClose: @escaping () -> Void) {
        presented = model
        self.onClose = onClose
    }

    func dismissRecentTabSwitcher() {
        dismissCount += 1
    }
}

/// Serialized because a switch in progress is app-wide: the editor's key chain finds it through one
/// static, and two tests holding switches at once would each see the other's.
@Suite("Recent tab switcher controller", .serialized)
@MainActor
struct RecentTabSwitcherControllerTests {
    private let presenter = RecordingPresenter()
    private let list: [RecentTabCandidate] = {
        let connection = UUID()
        return (0..<4).map { index in
            RecentTabCandidate(
                reference: RecentTabReference(connectionId: connection, tabId: UUID()),
                title: "Tab \(index)",
                detail: "",
                symbolName: "doc.text"
            )
        }
    }()

    private final class Recorder {
        var committed: [RecentTabReference] = []
        var announced: [String] = []
    }

    private func makeController(_ recorder: Recorder, pickerDelay: TimeInterval = 600) -> RecentTabSwitcherController {
        RecentTabSwitcherController(
            presenter: presenter,
            pickerDelay: pickerDelay,
            bindings: {
                (forward: .special(.tab, control: true), backward: .special(.tab, shift: true, control: true))
            },
            announce: { recorder.announced.append($0) }
        )
    }

    private func controlTab(shift: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: shift ? [.control, .shift] : .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: shift ? "\u{19}" : "\t",
            charactersIgnoringModifiers: shift ? "\u{19}" : "\t",
            isARepeat: false,
            keyCode: KeyCode.tab.rawValue
        ))
    }

    private func begin(
        _ controller: RecentTabSwitcherController,
        _ recorder: Recorder,
        trigger: NSEvent?,
        direction: RecentTabSwitchDirection = .forward,
        isOpen: @escaping (RecentTabReference) -> Bool = { _ in true }
    ) {
        controller.begin(
            candidates: list,
            direction: direction,
            trigger: trigger,
            window: nil,
            isOpen: isOpen,
            onCommit: { recorder.committed.append($0) }
        )
    }

    @Test("Chosen from the menu with the pointer, it switches to the previous tab at once")
    func pointerSwitchesAtOnce() {
        let recorder = Recorder()
        let controller = makeController(recorder)

        begin(controller, recorder, trigger: nil)

        #expect(recorder.committed == [list[1].reference])
        #expect(controller.isActive == false)
        #expect(presenter.presented == nil)
    }

    @Test("A tap lands on the previous tab when Control comes up, with no list drawn")
    func tapSwitchesOnRelease() throws {
        let recorder = Recorder()
        let controller = makeController(recorder)

        begin(controller, recorder, trigger: try controlTab())
        controller.handleModifiersChanged([])

        #expect(recorder.committed == [list[1].reference])
        #expect(controller.isActive == false)
        #expect(presenter.presented == nil)
    }

    @Test("Holding Control, each Tab moves on, and letting go switches there")
    func holdCycleRelease() throws {
        let recorder = Recorder()
        let controller = makeController(recorder)

        begin(controller, recorder, trigger: try controlTab())
        #expect(controller.isActive)
        #expect(recorder.committed.isEmpty)

        #expect(controller.handleKeyDown(keyCode: KeyCode.tab.rawValue, modifiers: .control))
        #expect(controller.session?.highlightedIndex == 2)

        controller.handleModifiersChanged([])

        #expect(recorder.committed == [list[2].reference])
        #expect(recorder.announced == ["Tab 1", "Tab 2"])
        #expect(controller.isActive == false)
    }

    @Test("Shift walks back, and the reverse chord starts at the tab used longest ago")
    func shiftWalksBack() throws {
        let recorder = Recorder()
        let controller = makeController(recorder)

        begin(controller, recorder, trigger: try controlTab(shift: true), direction: .backward)
        #expect(controller.session?.highlightedIndex == 3)

        controller.handleKeyDown(keyCode: KeyCode.tab.rawValue, modifiers: [.control, .shift])
        controller.handleModifiersChanged([])

        #expect(recorder.committed == [list[2].reference])
    }

    @Test("A modifier change that keeps Control down does not switch")
    func shiftAloneDoesNotCommit() throws {
        let recorder = Recorder()
        let controller = makeController(recorder)
        begin(controller, recorder, trigger: try controlTab())

        controller.handleModifiersChanged([.control, .shift])

        #expect(controller.isActive)
        #expect(recorder.committed.isEmpty)
        controller.cancel()
    }

    @Test("Escape ends the switch where it started")
    func escapeCancels() throws {
        let recorder = Recorder()
        let controller = makeController(recorder)
        begin(controller, recorder, trigger: try controlTab())

        controller.handleKeyDown(keyCode: KeyCode.escape.rawValue, modifiers: .control)
        controller.handleModifiersChanged([])

        #expect(recorder.committed.isEmpty)
        #expect(controller.isActive == false)
    }

    @Test("A tab that closed while the chord was held is not switched to")
    func closedTargetIsNotCommitted() throws {
        let recorder = Recorder()
        let controller = makeController(recorder)
        let closed = list[1].reference
        begin(controller, recorder, trigger: try controlTab(), isOpen: { $0 != closed })

        controller.handleModifiersChanged([])

        #expect(recorder.committed.isEmpty)
    }

    @Test("A quick tap never draws the list, and a held switch draws it after the delay")
    func pickerWaitsForTheDelay() async throws {
        let recorder = Recorder()
        let controller = makeController(recorder, pickerDelay: 0)
        begin(controller, recorder, trigger: try controlTab())
        #expect(presenter.presented == nil)

        try await Task.sleep(for: .milliseconds(200))

        #expect(presenter.presented?.session.highlightedIndex == 1)
        controller.handleModifiersChanged([])
        #expect(presenter.dismissCount == 1)
    }

    @Test("Another panel replacing the list ends the switch without switching")
    func panelCloseCancels() async throws {
        let recorder = Recorder()
        let controller = makeController(recorder, pickerDelay: 0)
        begin(controller, recorder, trigger: try controlTab())
        try await Task.sleep(for: .milliseconds(200))
        let onClose = try #require(presenter.onClose)

        onClose()

        #expect(controller.isActive == false)
        #expect(recorder.committed.isEmpty)
    }

    @Test("While a switch is held the editor's key chain hands its keys to it")
    func editorChainDefersToTheSwitch() throws {
        let recorder = Recorder()
        let controller = makeController(recorder)
        let press = try controlTab()
        #expect(RecentTabSwitcherController.claimKeyDown(press) == false)

        begin(controller, recorder, trigger: press)

        #expect(RecentTabSwitcherController.claimKeyDown(press))
        #expect(controller.session?.highlightedIndex == 2)
        controller.cancel()
        #expect(RecentTabSwitcherController.claimKeyDown(press) == false)
    }

    @Test("With no tab on screen, the switch lands on the most recent tab rather than the second")
    func noCurrentTabLandsOnTheFirstCandidate() {
        let recorder = Recorder()
        let controller = makeController(recorder)

        controller.begin(
            candidates: list,
            leadsWithCurrentTab: false,
            direction: .forward,
            trigger: nil,
            window: nil,
            isOpen: { _ in true },
            onCommit: { recorder.committed.append($0) }
        )

        #expect(recorder.committed == [list[0].reference])
    }

    /// AppKit runs no local monitor while a menu or a drag tracks, so a Control released there never
    /// arrives. The next key shows it: the switch has to end and let that key through rather than
    /// swallow it and every key after.
    @Test("A key that arrives without the held modifier ends the switch and passes through")
    func missedReleaseEndsTheSwitch() throws {
        let recorder = Recorder()
        let controller = makeController(recorder)
        begin(controller, recorder, trigger: try controlTab())

        let consumed = controller.handleKeyDown(keyCode: KeyCode.a.rawValue, modifiers: [])

        #expect(consumed == false)
        #expect(controller.isActive == false)
        #expect(recorder.committed.isEmpty)
    }

    @Test("One tab is nothing to switch to")
    func singleTabDoesNothing() throws {
        let recorder = Recorder()
        let controller = makeController(recorder)

        controller.begin(
            candidates: Array(list.prefix(1)),
            direction: .forward,
            trigger: try controlTab(),
            window: nil,
            isOpen: { _ in true },
            onCommit: { recorder.committed.append($0) }
        )

        #expect(controller.isActive == false)
        #expect(recorder.committed.isEmpty)
    }
}
