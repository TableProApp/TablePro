import XCTest

// #2927: the completion list over a filter field preselected its first row, so Return took a suggestion
// and left the filter unapplied. #3066: a cell's menu filters the table by the clicked value.
// Clear proves a filter ran: it is enabled only while one is applied.
final class FilterBarReturnUITests: UITestCase {
    func testFilteringFromACellAndFromTheFilterBar() throws {
        let (launch, grid) = try launchWithFixtureTable("album")
        let window = launch.window
        let app = launch.app
        let clear = window.buttons["Clear"].firstMatch

        app.typeShortcut(.toggleFilters)
        // A raw SQL row wraps its text, so its field is not assumed to be a single-line text field.
        let whereField = window.descendants(matching: .any)
            .matching(NSPredicate(
                format: "label == %@ AND (elementType == %lu OR elementType == %lu)",
                "WHERE clause",
                XCUIElement.ElementType.textField.rawValue,
                XCUIElement.ElementType.textView.rawValue
            ))
            .firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 15) { self.holdsKeyboardFocus(whereField) },
            "The filter bar must open on a raw SQL row with the keyboard in it"
        )
        let filter = "artist_id > 2 AND title IS NOT NULL"
        app.typeText(filter)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { (whereField.value as? String) == filter },
            "The typed filter must reach the WHERE field"
        )
        XCTAssertTrue(
            window.popovers.firstMatch.waitToExist(timeout: 10),
            "The completion list must be open on the NULL keyword when Return is pressed"
        )
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            waitForPredicate(timeout: 15) { clear.exists && clear.isEnabled },
            "Return must apply the filter while the completion list is open"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 20) {
                grid.value(row: 1, column: 2) == "West" && !grid.cell(row: 4, column: 2).exists
            },
            "The filter must leave the three albums of artists 3 to 5"
        )

        let cell = grid.cellPoint(row: 1, column: 2)
        cell.click()
        cell.rightClick()
        let filterMenu = window.menus.menuItems["Filter"].firstMatch
        XCTAssertTrue(filterMenu.waitToExist(timeout: 15), "A cell's context menu must offer Filter")
        filterMenu.hover()
        let equalsItems = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", " = \u{201C}West"))
        var equals: XCUIElement?
        XCTAssertTrue(
            waitForPredicate(timeout: 10) {
                equals = equalsItems.allElementsBoundByIndex.first { $0.isHittable }
                return equals != nil
            },
            "The Filter submenu must offer an equals condition built from the clicked value"
        )
        try XCTUnwrap(equals).click()

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { !grid.cell(row: 2, column: 2).exists },
            "Choosing the condition must narrow the table to the clicked row"
        )
        XCTAssertEqual(grid.value(row: 1, column: 2), "West", "The row that was clicked must stay")
        XCTAssertTrue(clear.isEnabled, "The filter bar must report a filter applied")
    }
}
