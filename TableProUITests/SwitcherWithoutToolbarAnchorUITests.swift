//
//  SwitcherWithoutToolbarAnchorUITests.swift
//  TableProUITests
//
//  Covers the defect class where a command that has a menu item and a keyboard shortcut is the
//  only thing that can present a chooser, but the chooser is declared inside a toolbar item's own
//  view. AppKit clips a toolbar item into the overflow menu on a narrow window and lets the user
//  delete it outright in Customize Toolbar, and in both states that view is not on screen, so the
//  command set its flag and nothing appeared: no popover, no error, no feedback.
//

import XCTest

/// Hiding the toolbar is the deterministic way to reach the no-anchor state from a test.
///
/// The state CI actually failed in is an overflowed item on a 1024pt screen, which cannot be
/// reproduced on a developer machine: `recomputeWindowMinSize()` puts the window's minimum width
/// near 1364pt with a table tab open, so a pinned frame is clamped back up and the toolbar never
/// runs out of room. Hiding the toolbar removes the anchor the same way, through a route any
/// machine can take, and it exercises the same branch.
final class SwitcherWithoutToolbarAnchorUITests: UITestCase {
    func testSwitchConnectionOpensWithTheToolbarHidden() throws {
        let app = try launchWithSampleDatabase()
        try waitForGrid(in: app)

        let toolbar = app.windows.firstMatch.toolbars.firstMatch
        /// Normalised rather than asserted. `MainWindowToolbar` sets `autosavesConfiguration`, and
        /// AppKit persists toolbar visibility through its own defaults rather than the sandbox
        /// `UITestCase` hands the app, so this suite inherits whatever the last run left behind,
        /// including its own. An earlier version of this test hid the toolbar without restoring it
        /// and every later run then failed on a precondition instead of on the behaviour.
        setToolbar(shown: true, toolbar: toolbar, in: app)
        setToolbar(shown: false, toolbar: toolbar, in: app)
        /// Restored even when an assertion below fails. `MainWindowToolbar` sets
        /// `autosavesConfiguration`, and AppKit persists that visibility through its own defaults
        /// rather than the sandbox `UITestCase` hands the app, so leaving the toolbar hidden would
        /// hide it for every later launch on the machine and fail suites that have nothing to do
        /// with this one.
        defer { setToolbar(shown: true, toolbar: toolbar, in: app) }

        app.typeKey("c", modifierFlags: [.command, .control])

        XCTAssertTrue(
            connectionSearchField(in: app).waitToExist(timeout: 15),
            "Switch Connection must present with no toolbar item to anchor to"
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Helpers

    /// Driven by the key equivalent rather than by walking the View menu, which
    /// `UITestCase.launchWithSampleDatabase` documents as the slow and flake-prone route. The menu
    /// item is built with a fixed "Show Toolbar" title in both states, so its label is no signal.
    private func setToolbar(shown: Bool, toolbar: XCUIElement, in app: XCUIApplication) {
        _ = toolbar.waitToExist(timeout: 3)
        guard toolbar.exists != shown else { return }
        app.typeKey("t", modifierFlags: [.command, .option])
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { toolbar.exists == shown },
            "Command Option T must \(shown ? "show" : "hide") the toolbar"
        )
    }

    private func waitForGrid(in app: XCUIApplication) throws {
        XCTAssertTrue(
            app.windows.firstMatch.tables.matching(identifier: "data-grid").firstMatch
                .waitToExist(timeout: 30)
        )
        app.activate()
    }

    /// Keyed on the placeholder because every `NativeSearchField` publishes the same default
    /// identifier, so an identifier match cannot tell the switcher surfaces apart. It is also what
    /// makes this assertion independent of which surface presented: popover or panel, the field is
    /// the same one.
    private func connectionSearchField(in app: XCUIApplication) -> XCUIElement {
        app.searchFields.matching(
            NSPredicate(format: "placeholderValue BEGINSWITH[c] %@", "Search connections")
        ).firstMatch
    }
}
