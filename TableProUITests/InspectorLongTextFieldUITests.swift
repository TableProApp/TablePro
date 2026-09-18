//
//  InspectorLongTextFieldUITests.swift
//  TableProUITests
//
//  The row inspector rendered a plain string in an NSTextField, which carries no scroll view at
//  any axis setting, so a value past the line limit was clipped with no way to reach the rest.
//  The element type is what separates the fix from the bug: a text view scrolls, a text field
//  cannot, and both report the same accessibility value.
//

import XCTest

final class InspectorLongTextFieldUITests: UITestCase {
    /// 1,998 characters on one line, produced by the sample database itself so the test needs no
    /// fixture. XCUITest synthesizes typing at roughly 113ms per character, so the query is short
    /// even though its result is not.
    private let query = "SELECT hex(zeroblob(999));"
    private let shortestAcceptedValue = 1_500

    func testALongValueOpensInAScrollingTextViewInTheInspector() throws {
        let app = try launchWithSampleDatabase()
        let editor = try runQuery(in: app)

        let window = app.windows.firstMatch
        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The query must produce a result grid")
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { !grid.tableRows.allElementsBoundByIndex.isEmpty },
            "The query must return a row; the editor holds '\(editor.value as? String ?? "nil")'"
        )

        showInspector(in: app)
        clickAtCenter(grid.tableRows.firstMatch)

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.longValueTextView(in: window) != nil },
            "A \(shortestAcceptedValue)+ character value must render in a text view, which "
                + "scrolls, rather than in a text field, which clips. Text view lengths present: "
                + "\(textViewLengths(in: window))"
        )
    }

    /// The editor has live autocompletion, and it costs this flow twice. Typing into a tab that is
    /// not ready yet loses and reorders characters, and a suggestion list still open when Command
    /// Return arrives takes the Return as an acceptance, so the run executed
    /// `SELECT hex(zeroblob(999));Total`. Waiting for the empty editor, then for the exact query,
    /// then dismissing the list, is what makes it deterministic; without it the failure surfaces
    /// much later as a query that returned no rows.
    private func runQuery(in app: XCUIApplication) throws -> XCUIElement {
        app.typeKey("t", modifierFlags: .command)

        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 15))
        XCTAssertTrue(
            waitForValue("", in: editor, timeout: 15),
            "A new tab starts with an empty editor; got '\(editor.value as? String ?? "nil")'"
        )

        app.typeText(query)
        XCTAssertTrue(
            waitForValue(query, in: editor, timeout: 15),
            "Every typed character must land in the editor; got '\(editor.value as? String ?? "nil")'"
        )

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitForValue(query, in: editor, timeout: 5),
            "Dismissing the suggestion list must leave the query alone; got "
                + "'\(editor.value as? String ?? "nil")'"
        )

        app.typeKey(.return, modifierFlags: .command)
        return editor
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

    private func waitForValue(_ expected: String, in element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitForPredicate(timeout: timeout) { (element.value as? String) == expected }
    }

    private func longValueTextView(in window: XCUIElement) -> XCUIElement? {
        window.textViews.allElementsBoundByIndex.first { element in
            (element.value as? String)?.count ?? 0 >= shortestAcceptedValue
        }
    }

    private func textViewLengths(in window: XCUIElement) -> [Int] {
        window.textViews.allElementsBoundByIndex.map { ($0.value as? String)?.count ?? -1 }
    }
}
