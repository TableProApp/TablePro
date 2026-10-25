import XCTest

// A match becomes the grid's cell cursor, so the row that holds it is the selected row. Of album's titles only
// East (row 3) and West (row 4) hold "st".
final class GridFindUITests: UITestCase {
    func testFindStepsThroughMatchesAndEscapeHandsTheKeyboardBack() throws {
        let (launch, grid) = try launchWithFixtureTable("album")
        let window = launch.window
        let app = launch.app
        XCTAssertTrue(grid.waitForValue("North", row: 1, column: 2), "album must open on its first row")
        grid.clickCell(row: 1, column: 2)

        app.typeShortcut(.find)
        let field = window.descendants(matching: .any).matching(identifier: "grid-find-field").firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.holdsKeyboardFocus(field) },
            "Cmd+F must open the grid's find bar with the keyboard in its field"
        )
        app.typeText("st")

        let count = window.staticTexts.matching(identifier: "grid-find-count").firstMatch
        let rows = grid.element.tableRows
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.text(of: count) == "1 of 2" && rows.element(boundBy: 2).isSelected },
            "The first match must be East on row 3, the counter reads '\(text(of: count))'"
        )

        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            waitForPredicate(timeout: 10) {
                self.text(of: count) == "2 of 2" && rows.element(boundBy: 3).isSelected && !rows.element(boundBy: 2).isSelected
            },
            "Return must move to West on row 4, the counter reads '\(text(of: count))'"
        )

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForPredicate(timeout: 10) { !field.exists }, "Escape in the field must close the find bar")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.holdsKeyboardFocus(grid.element) },
            "Closing the find bar must hand the keyboard back to the grid"
        )
    }

    // A SwiftUI text publishes its string as the value on some builds and as the label on others.
    private func text(of element: XCUIElement) -> String {
        guard element.exists else { return "" }
        return (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }
}
