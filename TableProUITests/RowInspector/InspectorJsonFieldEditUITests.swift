//
//  InspectorJsonFieldEditUITests.swift
//  TableProUITests
//
//  The row inspector's JSON field kept two mirrors of one value in two textual forms and
//  reconciled them from an `onChange` action that re-read a context a render out of date. Typing
//  one character made the editor put the previous value back and push it into the store again, at
//  about 75 rounds a second: one keystroke produced 6,944 body evaluations in 30 seconds at 100%
//  CPU, and the character was thrown away (#3051).
//
//  So the assertion is not "the app is responsive", which is hard to state and easy to pass by
//  accident. It is that the character is still there afterwards, which the loop could not manage.
//

import XCTest

final class InspectorJsonFieldEditUITests: UITestCase {
    /// Chinook has no JSON column and no text value that parses as a JSON object, so the app seeds
    /// one when this variable is set. Both sides spell the name out because a UI test target cannot
    /// import the app.
    private let jsonFixtureVariable = "TABLEPRO_UI_TEST_SEED_JSON_TABLE"
    private let fixtureTable = "json_fixture"
    private let typedMarker = "ZZTOP"

    func testTypingInTheJsonFieldKeepsWhatWasTyped() throws {
        let app = try launchWithSampleDatabase(environment: [jsonFixtureVariable: "1"])
        let window = app.windows.firstMatch

        try openFixtureTable(in: app)
        showInspector(in: app)

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The fixture table must produce a result grid")
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { grid.tableRows.firstMatch.exists },
            "The fixture table must return a row"
        )
        gridPoint(in: grid, of: window, dy: 12).click()

        let field = window.textViews.matching(identifier: "inspector-json-field").firstMatch
        XCTAssertTrue(field.waitToExist(timeout: 20), "The JSON column must open the JSON editor")

        let before = field.value as? String ?? ""
        XCTAssertTrue(before.contains("\"name\""), "The fixture document must be in the editor, got '\(before)'")

        field.click()
        app.typeText(typedMarker)

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { (field.value as? String)?.contains(self.typedMarker) == true },
            "Every typed character must survive; the editor holds '\(field.value as? String ?? "nil")'"
        )

        /// The loop put the pre-edit text back a moment after the keystroke, so one check could
        /// pass on timing alone. Letting the run loop turn and asking again is what separates
        /// "typed" from "kept".
        _ = waitForPredicate(timeout: 3) { false }
        XCTAssertTrue(
            (field.value as? String)?.contains(typedMarker) ?? false,
            "The typed text must still be there a moment later; the editor holds "
                + "'\(field.value as? String ?? "nil")'"
        )
    }

    // MARK: - Helpers

    private func openFixtureTable(in app: XCUIApplication) throws {
        let browser = app.windows.firstMatch.outlines.firstMatch
        XCTAssertTrue(browser.waitToExist(timeout: 30), "The object browser must list the sample's tables")

        let table = browser.staticTexts[fixtureTable].firstMatch
        XCTAssertTrue(
            table.waitToExist(timeout: 30),
            "The seeded fixture table must appear in the object browser"
        )
        table.doubleClick()
    }

    /// The inspector remembers whether it was open, so the starting state is whatever the previous
    /// launch left. The View menu item reads Hide Inspector once it is showing, which is the only
    /// handle on that state.
    private func showInspector(in app: XCUIApplication) {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))
        menuBar.menuBarItems["View"].click()

        let show = menuBar.menuItems["Show Inspector"]
        if show.waitToExist(timeout: 5) {
            show.click()
            return
        }
        app.typeKey(.escape, modifierFlags: [])
    }
}
