import XCTest

// #3613: Generate Rows fills a table from its row menu, and a foreign key column only takes keys that exist.
final class GenerateRowsUITests: UITestCase {
    func testGenerateRowsInsertsRowsThatReferenceExistingParents() throws {
        let launch = try launchWithFixture()
        let window = launch.window
        let app = launch.app

        rightClickInObjectBrowser("album", in: window)
        let generate = contextMenuItem("Generate Rows…", in: app)
        XCTAssertTrue(generate.waitToExist(timeout: 10), "Generate Rows must be on a table row's contextual menu")
        generate.click()

        let sheet = window.children(matching: .sheet).firstMatch
        let start = sheet.buttons.matching(identifier: "generate-rows-start").firstMatch
        XCTAssertTrue(waitUntilHittable(start, timeout: 30), "Generate Rows must open a sheet once it has read the table")
        XCTAssertTrue(
            sheet.descendants(matching: .any).matching(identifier: "generate-rows-preview").firstMatch.waitToExist(timeout: 20),
            "The sheet must preview the first rows"
        )
        XCTAssertTrue(waitForPredicate(timeout: 20) { start.isEnabled }, "The default settings must be ready to run")
        start.click()

        let result = sheet.staticTexts.matching(identifier: "generate-rows-result").firstMatch
        XCTAssertTrue(result.waitToExist(timeout: 60), "The run must finish and say what it did")
        XCTAssertTrue(
            (result.value as? String ?? result.label).contains("Inserted 100 rows"),
            "The default run inserts 100 rows"
        )

        sheet.buttons.matching(identifier: "generate-rows-done").firstMatch.click()
        XCTAssertTrue(waitForPredicate(timeout: 20) { !sheet.exists }, "Done must close the sheet")

        let counts = FixtureFile.rows(
            "SELECT COUNT(*), SUM(artist_id NOT IN (SELECT id FROM artist)), COUNT(DISTINCT id) FROM album",
            in: launch.database
        )
        XCTAssertEqual(counts?.first, ["106", "0", "106"], "Every new album must point at an artist that exists")
    }
}
