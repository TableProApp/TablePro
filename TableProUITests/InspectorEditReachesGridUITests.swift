import XCTest

// #2851: an inspector edit stopped at the inspector, so the grid kept drawing the old value. #3051: the
// JSON field put the previous value back after every keystroke and pushed it into the store again.
final class InspectorEditReachesGridUITests: UITestCase {
    func testInspectorEditsReachTheGrid() throws {
        let (launch, grid) = try launchWithFixtureTable("document")
        let window = launch.window
        let app = launch.app

        grid.clickCell(row: 1, column: 2)
        app.typeShortcut(.toggleInspector)

        let labelField = window.textFields.matching(NSPredicate(format: "value == %@", "First")).firstMatch
        XCTAssertTrue(waitUntilHittable(labelField, timeout: 30), "The inspector must show row 1's label field")
        labelField.click()
        app.typeText("Zq7")
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { grid.value(row: 1, column: 2)?.contains("Zq7") == true },
            "A field edited in the inspector must reach the grid cell without a save, the cell holds "
                + "'\(grid.value(row: 1, column: 2) ?? "nil")'"
        )

        let jsonField = window.textViews.matching(identifier: "inspector-json-field").firstMatch
        XCTAssertTrue(jsonField.waitToExist(timeout: 20), "payload holds a JSON object, so it must open the JSON editor")
        XCTAssertTrue(
            (jsonField.value as? String)?.contains("\"seats\"") == true,
            "The JSON editor must hold row 1's payload"
        )
        jsonField.click()
        app.typeText("ZZTOP")

        // The grid holding the text means the edit made the round trip through the store that used to undo it.
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { grid.value(row: 1, column: 3)?.contains("ZZTOP") == true },
            "Text typed in the JSON field must reach the grid cell"
        )
        XCTAssertTrue(
            (jsonField.value as? String)?.contains("ZZTOP") == true,
            "The JSON field must keep what was typed, it holds '\(jsonField.value as? String ?? "nil")'"
        )
    }
}
