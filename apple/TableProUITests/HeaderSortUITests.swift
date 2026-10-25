import XCTest

final class HeaderSortUITests: UITestCase {
    // album's titles put the server order, ascending and descending on three different first rows. Artist 2
    // holds South then East, so a title key behind artist_id shows as East on row 2.
    func testHeaderClicksFlipTheSortOptionClickAddsAKeyAndDontSortSurvivesAReload() throws {
        let (launch, grid) = try launchWithFixtureTable("album")
        XCTAssertTrue(grid.waitForValue("North", row: 1, column: 2), "album must open in the order the server sent")

        grid.clickHeader("title")
        XCTAssertTrue(grid.waitForValue("Down", row: 1, column: 2), "The first click must sort ascending")

        grid.clickHeader("title")
        XCTAssertTrue(grid.waitForValue("West", row: 1, column: 2), "The second click must sort descending")

        grid.clickHeader("title")
        XCTAssertTrue(
            grid.waitForValue("Down", row: 1, column: 2),
            "A third click must flip back to ascending, never return to the server's order"
        )

        grid.clickHeader("artist_id")
        XCTAssertTrue(
            grid.waitForValue("North", row: 1, column: 2),
            "A plain click on another header must replace the title sort with artist_id"
        )

        grid.clickHeader("title", modifiers: .option)
        XCTAssertTrue(
            waitForPredicate(timeout: 20) {
                grid.value(row: 1, column: 2) == "North" && grid.value(row: 2, column: 2) == "East"
            },
            "Option-click must add title behind artist_id, row 2 reads '\(grid.value(row: 2, column: 2) ?? "nil")'"
        )

        grid.clickHeader("title")
        XCTAssertTrue(
            grid.waitForValue("Down", row: 1, column: 2),
            "A plain click on the second key must sort by title alone"
        )

        grid.clickHeader("title", rightClick: true)
        let dontSort = contextMenuItem("Don't Sort", in: launch.app)
        XCTAssertTrue(dontSort.waitToExist(timeout: 10), "The header menu must offer Don't Sort while sorting")
        dontSort.click()
        XCTAssertTrue(
            grid.waitForValue("North", row: 1, column: 2),
            "Don't Sort must return to the order the server sent"
        )

        // Renamed behind the app's back, so the first row shows the refresh landed and in which order.
        XCTAssertTrue(FixtureFile.execute("UPDATE album SET title = 'Norte' WHERE id = 1", in: launch.database))
        launch.app.typeShortcut(.refresh)
        XCTAssertTrue(
            grid.waitForValue("Norte", row: 1, column: 2),
            "A refresh must keep the server's order rather than put a sort back over Don't Sort, "
                + "row 1 reads '\(grid.value(row: 1, column: 2) ?? "nil")'"
        )
    }
}
