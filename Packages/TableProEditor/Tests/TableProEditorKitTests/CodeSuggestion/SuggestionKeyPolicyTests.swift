import AppKit
import Carbon.HIToolbox
@testable import TableProEditorKit
import XCTest

/// The panel is consulted from a local key-down monitor, and a monitor that returns nil stops the
/// event before the main menu sees it. Measured in a standalone AppKit harness: with the monitor
/// consuming, a menu item bound to the same chord never fires at all.
final class SuggestionKeyPolicyTests: XCTestCase {
    private let bare = NSEvent.ModifierFlags()

    func test_selectedList_ownsTheBareKeysItCanActOn() {
        XCTAssertEqual(outcome(kVK_Escape, bare, true), .dismiss)
        XCTAssertEqual(outcome(kVK_DownArrow, bare, true), .moveSelection(1))
        XCTAssertEqual(outcome(kVK_UpArrow, bare, true), .moveSelection(-1))
        XCTAssertEqual(outcome(kVK_Return, bare, true), .applySelection)
        XCTAssertEqual(outcome(kVK_Tab, bare, true), .applySelection)
    }

    func test_listWithNothingSelected_dismissesInsteadOfSwallowing() {
        XCTAssertEqual(outcome(kVK_Return, bare, false), .dismiss)
        XCTAssertEqual(outcome(kVK_Tab, bare, false), .dismiss)
        XCTAssertEqual(outcome(kVK_DownArrow, bare, false), .dismiss)
        XCTAssertEqual(outcome(kVK_UpArrow, bare, false), .dismiss)
        XCTAssertEqual(outcome(kVK_Escape, bare, false), .dismiss)
    }

    /// The released defect: every arm consumed the event on the key code alone, so the panel
    /// answered for `Cmd+Return` and Execute Query never ran while the list was up.
    func test_aChordWithAModifierBelongsToWhoeverBoundIt() {
        for modifiers: NSEvent.ModifierFlags in [.command, [.command, .shift], [.command, .option], .shift, .control] {
            XCTAssertEqual(outcome(kVK_Return, modifiers, true), .passThrough)
            XCTAssertEqual(outcome(kVK_Tab, modifiers, true), .passThrough)
            XCTAssertEqual(outcome(kVK_Escape, modifiers, true), .passThrough)
            XCTAssertEqual(outcome(kVK_DownArrow, modifiers, true), .passThrough)
        }
    }

    /// An arrow key arrives carrying `.function` on a real keyboard, so the modifier guard has to
    /// ignore it or the panel stops answering for `Up` and `Down` entirely.
    func test_theFunctionFlagAnArrowKeyCarriesIsNotAModifier() {
        XCTAssertEqual(outcome(kVK_DownArrow, .function, true), .moveSelection(1))
        XCTAssertEqual(outcome(kVK_UpArrow, .function, true), .moveSelection(-1))
    }

    func test_anyOtherKeyReachesTheEditor() {
        XCTAssertEqual(outcome(kVK_ANSI_A, bare, true), .passThrough)
        XCTAssertEqual(outcome(kVK_Space, bare, false), .passThrough)
    }

    private func outcome(
        _ keyCode: Int,
        _ modifiers: NSEvent.ModifierFlags,
        _ hasSelection: Bool
    ) -> SuggestionKeyOutcome {
        SuggestionKeyPolicy.outcome(forKeyCode: keyCode, modifiers: modifiers, hasSelection: hasSelection)
    }
}
