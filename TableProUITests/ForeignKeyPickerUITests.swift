import XCTest

final class ForeignKeyPickerUITests: UITestCase {
    func testEditingAForeignKeyCellListsAndNarrowsTheReferencedRows() throws {
        let (launch, grid) = try launchWithFixtureTable("album")
        let window = launch.window
        let app = launch.app

        grid.clickCell(row: 1, column: 2)
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])

        let search = window.searchFields.matching(identifier: "fk-picker-search").firstMatch
        XCTAssertTrue(search.waitToExist(timeout: 20), "Editing album.artist_id must open the value picker")
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.staticTexts["Ada"].exists && window.staticTexts["Cole"].exists },
            "The picker must list artist rows labelled with their name"
        )

        app.typeText("Cole")
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { !window.staticTexts["Ada"].exists && window.staticTexts["Cole"].exists },
            "Searching Cole must keep the artist of that name and drop every row it does not match"
        )
    }
}
