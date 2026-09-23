//
//  RecentTabSwitcherSessionTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

private func candidates(_ count: Int) -> [RecentTabCandidate] {
    let connection = UUID()
    return (0..<count).map { index in
        RecentTabCandidate(
            reference: RecentTabReference(connectionId: connection, tabId: UUID()),
            title: "Tab \(index)",
            detail: "",
            symbolName: "doc.text"
        )
    }
}

@Suite("Recent tab switcher session")
struct RecentTabSwitcherSessionTests {
    @Test("Nothing to switch to with fewer than two tabs")
    func needsTwoCandidates() {
        #expect(RecentTabSwitcherSession(candidates: candidates(1), direction: .forward) == nil)
        #expect(RecentTabSwitcherSession(candidates: [], direction: .backward) == nil)
    }

    @Test("Forward starts on the tab used before this one, backward on the one used longest ago")
    func startingIndex() throws {
        let list = candidates(4)
        let forward = try #require(RecentTabSwitcherSession(candidates: list, direction: .forward))
        let backward = try #require(RecentTabSwitcherSession(candidates: list, direction: .backward))

        #expect(forward.highlightedIndex == 1)
        #expect(backward.highlightedIndex == 3)
    }

    @Test("Stepping wraps through the tab on screen in both directions")
    func steppingWraps() throws {
        var session = try #require(RecentTabSwitcherSession(candidates: candidates(3), direction: .forward))

        session.step(.forward)
        #expect(session.highlightedIndex == 2)
        session.step(.forward)
        #expect(session.highlightedIndex == 0)
        session.step(.backward)
        #expect(session.highlightedIndex == 2)
    }

    @Test("A tab that closed elsewhere in the list is dropped and the step carries on")
    func closedCandidateIsDropped() throws {
        let list = candidates(4)
        var session = try #require(RecentTabSwitcherSession(candidates: list, direction: .forward))
        let closed = list[3].reference

        #expect(session.step(.forward) { $0 != closed })
        #expect(session.candidates.count == 3)
        #expect(session.highlighted.reference == list[2].reference)
    }

    /// Closing the highlighted tab already moves the list up under the highlight; stepping from
    /// there again passed over the tab that followed it.
    @Test("With the highlighted tab closed, forward lands on the tab after it")
    func closedHighlightForward() throws {
        let list = candidates(3)
        var session = try #require(RecentTabSwitcherSession(candidates: list, direction: .forward))
        let closed = list[1].reference

        #expect(session.step(.forward) { $0 != closed })
        #expect(session.highlighted.reference == list[2].reference)
    }

    @Test("With the highlighted tab closed, backward lands on the tab before it")
    func closedHighlightBackward() throws {
        let list = candidates(4)
        var session = try #require(RecentTabSwitcherSession(candidates: list, direction: .forward))
        session.step(.forward)
        let closed = list[2].reference

        #expect(session.step(.backward) { $0 != closed })
        #expect(session.highlighted.reference == list[1].reference)
    }

    @Test("With the last tab highlighted and closed, forward wraps to the first")
    func closedLastHighlightWraps() throws {
        let list = candidates(3)
        var session = try #require(RecentTabSwitcherSession(candidates: list, direction: .backward))
        let closed = list[2].reference

        #expect(session.step(.forward) { $0 != closed })
        #expect(session.highlighted.reference == list[0].reference)
    }

    /// The connection on screen can have every tab closed while another connection in the window
    /// still has some. Then no candidate is the current tab, and skipping the first would pass over
    /// the most recent one.
    @Test("With no tab on screen, forward starts on the most recent tab and one candidate is enough")
    func noCurrentTab() throws {
        let one = candidates(1)
        let session = try #require(RecentTabSwitcherSession(candidates: one, direction: .forward, leadsWithCurrentTab: false))
        let three = try #require(RecentTabSwitcherSession(candidates: candidates(3), direction: .forward, leadsWithCurrentTab: false))
        let reverse = try #require(RecentTabSwitcherSession(candidates: candidates(3), direction: .backward, leadsWithCurrentTab: false))

        #expect(session.highlighted.reference == one[0].reference)
        #expect(three.highlightedIndex == 0)
        #expect(reverse.highlightedIndex == 2)
        #expect(RecentTabSwitcherSession(candidates: [], direction: .forward, leadsWithCurrentTab: false) == nil)
    }

    @Test("Once only the tab on screen is left there is nothing to switch to")
    func lastCandidateEndsTheSwitch() throws {
        let list = candidates(2)
        var session = try #require(RecentTabSwitcherSession(candidates: list, direction: .forward))

        #expect(session.step(.forward) { $0 == list[0].reference } == false)
    }
}

@Suite("Recent tab switcher keys")
struct RecentTabSwitcherKeyCommandTests {
    private func resolve(
        _ key: KeyCode,
        _ modifiers: NSEvent.ModifierFlags,
        forward: BoundKey? = .special(.tab, control: true),
        backward: BoundKey? = .special(.tab, shift: true, control: true)
    ) -> RecentTabSwitcherKeyCommand {
        RecentTabSwitcherKeyCommand.resolve(keyCode: key.rawValue, modifiers: modifiers, forward: forward, backward: backward)
    }

    @Test("The two chords step forward and back")
    func chordsStep() {
        #expect(resolve(.tab, .control) == .step(.forward))
        #expect(resolve(.tab, [.control, .shift]) == .step(.backward))
    }

    @Test("Shift reverses the forward chord even when nothing is bound to the reverse one")
    func shiftReversesWithoutAReverseBinding() {
        #expect(resolve(.tab, [.control, .shift], backward: nil) == .step(.backward))
    }

    @Test("A rebound chord steps too, and the old one does nothing")
    func reboundChord() {
        let rebound = BoundKey.special(.space, option: true)

        #expect(resolve(.tab, .control, forward: rebound, backward: nil) == .ignore)
        #expect(resolve(.space, .option, forward: rebound, backward: nil) == .step(.forward))
        #expect(resolve(.space, [.option, .shift], forward: rebound, backward: nil) == .step(.backward))
    }

    /// A chord can be rebound to Control-Return or Control-Escape. Read as commit or cancel, every
    /// press after the first would end the switch it started.
    @Test("A binding on Return or Escape steps instead of committing or cancelling")
    func bindingsWinOverControlKeys() {
        #expect(resolve(.return, .control, forward: .special(.return, control: true), backward: nil) == .step(.forward))
        #expect(resolve(.escape, .control, forward: .special(.escape, control: true), backward: nil) == .step(.forward))
        #expect(resolve(.return, .control, forward: .special(.tab, control: true), backward: nil) == .commit)
    }

    @Test("Escape cancels, Return commits, and the arrows move")
    func controlKeys() {
        #expect(resolve(.escape, .control) == .cancel)
        #expect(resolve(.return, .control) == .commit)
        #expect(resolve(.enter, []) == .commit)
        #expect(resolve(.upArrow, []) == .step(.backward))
        #expect(resolve(.downArrow, []) == .step(.forward))
    }

    @Test("Any other key is swallowed")
    func otherKeysAreIgnored() {
        #expect(resolve(.a, .control) == .ignore)
        #expect(resolve(.tab, [.control, .option]) == .ignore)
    }

    @Test("The held modifiers come from the key press, never from Shift or a pointer")
    func heldModifiers() throws {
        let press = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{19}",
            charactersIgnoringModifiers: "\u{19}",
            isARepeat: false,
            keyCode: KeyCode.tab.rawValue
        ))

        #expect(RecentTabSwitcherKeyCommand.heldModifiers(of: press) == .control)
        #expect(RecentTabSwitcherKeyCommand.heldModifiers(of: nil).isEmpty)
    }

    @Test("Letting go of any held modifier ends the switch")
    func releases() {
        #expect(RecentTabSwitcherKeyCommand.releases([], held: .control))
        #expect(RecentTabSwitcherKeyCommand.releases(.command, held: [.command, .option]))
        #expect(RecentTabSwitcherKeyCommand.releases([.control, .shift], held: .control) == false)
    }
}
