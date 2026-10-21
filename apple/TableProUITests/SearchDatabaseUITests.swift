import XCTest

// #3601: Search Database finds which table holds a value and opens that table filtered to its rows.
final class SearchDatabaseUITests: UITestCase {
    func testSearchFindsTheTableHoldingAValueAndOpensItFiltered() throws {
        let launch = try launchWithFixture()
        let window = launch.window
        let app = launch.app

        menuItem("Search Database…", under: "Database", in: app).click()

        let sheet = window.children(matching: .sheet).firstMatch
        let term = sheet.textFields.matching(identifier: "database-search-term").firstMatch
        XCTAssertTrue(waitUntilHittable(term, timeout: 20), "Search Database must open a sheet with a value field")
        XCTAssertTrue(
            sheet.descendants(matching: .any).matching(identifier: "database-search-tables").firstMatch
                .waitToExist(timeout: 30),
            "The sheet must list the tables it can search"
        )
        term.click()
        app.typeText("brook")

        let search = sheet.buttons.matching(identifier: "database-search-start").firstMatch
        XCTAssertTrue(waitForPredicate(timeout: 20) { search.isEnabled }, "Search must enable once a value is typed")
        search.click()

        let summary = sheet.staticTexts.matching(identifier: "database-search-summary").firstMatch
        XCTAssertTrue(summary.waitToExist(timeout: 60), "The search must finish and say what it found")
        XCTAssertTrue(
            (summary.value as? String ?? summary.label).contains("1 table holds"),
            "Only artist holds Brook"
        )

        let open = sheet.buttons.matching(identifier: "database-search-open").firstMatch
        XCTAssertTrue(waitForPredicate(timeout: 20) { open.isEnabled }, "The first match must be selected and openable")
        open.click()

        XCTAssertTrue(waitForPredicate(timeout: 20) { !sheet.exists }, "Opening a match must close the sheet")
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { self.editorTabs(titled: "artist", in: window).firstMatch.exists },
            "Opening a match must open its table in a tab"
        )
        let grid = fixtureGrid(in: window, app: app)
        XCTAssertTrue(grid.waitForValue("Brook", row: 1, column: 2, timeout: 30), "The tab must show the matching row")
        XCTAssertFalse(
            grid.cell(row: 2, column: 2).waitToExist(timeout: 2),
            "The tab must be filtered to the matching rows"
        )
    }
}
