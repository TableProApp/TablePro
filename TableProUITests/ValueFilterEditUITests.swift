import XCTest

final class ValueFilterEditUITests: UITestCase {
    private let savedValue = "Saved Under Filter"

    func testSavingAnEditKeepsTheValueFilter() throws {
        let (launch, grid) = try launchWithFixtureTable("album")
        let window = launch.window
        let app = launch.app

        grid.clickHeader("artist_id", rightClick: true)
        let filterValues = contextMenuItem("Filter Values…", in: app)
        XCTAssertTrue(filterValues.waitToExist(timeout: 10), "The header menu must offer Filter Values…")
        filterValues.click()

        let popover = window.popovers.firstMatch
        let search = popover.searchFields["value-filter-search"].firstMatch
        XCTAssertTrue(search.waitToExist(timeout: 10), "Filter Values… must open the value filter")
        search.typeText("2")
        let valueToggle = popover.checkBoxes.matching(identifier: "value-filter-value").firstMatch
        XCTAssertTrue(waitUntilHittable(valueToggle, timeout: 10), "The search must leave 2 in the list")
        let apply = popover.buttons["Apply"].firstMatch
        XCTAssertTrue(waitUntilHittable(apply, timeout: 10), "The value filter must offer Apply")
        apply.click()
        XCTAssertTrue(popover.waitForNonExistence(timeout: 10), "Apply must close the value filter")

        XCTAssertTrue(
            waitForPredicate(timeout: 20) {
                grid.value(row: 1, column: 2) == "South" && grid.value(row: 2, column: 2) == "East"
                    && !grid.cell(row: 3, column: 2).exists
            },
            "Keeping artist 2 must leave South and East"
        )

        grid.editCell(row: 2, column: 2, to: savedValue)
        XCTAssertTrue(grid.waitForValue(savedValue, row: 2, column: 2, timeout: 10), "The edit must land on East")

        // Renamed behind the app's back, so row 1 changes only once the save has read its rows back.
        XCTAssertTrue(FixtureFile.execute("UPDATE album SET title = 'Southbound' WHERE id = 2", in: launch.database))
        app.typeShortcut(.save)
        XCTAssertTrue(
            grid.waitForValue("Southbound", row: 1, column: 2, timeout: 30),
            "Save must read the rows back"
        )
        XCTAssertFalse(
            grid.cell(row: 3, column: 2).exists,
            "The rows read back after Save must still be filtered to artist 2"
        )
        XCTAssertEqual(grid.value(row: 2, column: 2), savedValue, "The saved value must be read back")
        XCTAssertEqual(
            FixtureFile.rows("SELECT title FROM album WHERE id = 3", in: launch.database),
            [[savedValue]],
            "Save must write the edit to the file"
        )
    }
}
