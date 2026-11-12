import XCTest

final class ManualCommitUITests: UITestCase {
    func testManualCommitHoldsAnUpdateUntilItIsRolledBack() throws {
        let launch = try launchWithFixture()
        let window = launch.window
        let app = launch.app
        XCTAssertTrue(app.menuBars.firstMatch.waitToExist(timeout: 20), "The app must publish its menu bar")

        menuItem("Manual Commit", under: "Database", in: app).click()
        typeQuery("UPDATE note SET body = 'Held' WHERE id = 1;", in: window)
        app.typeShortcut(.runQuery)

        let bar = window.descendants(matching: .any)["connection-transaction-bar"].firstMatch
        XCTAssertTrue(bar.waitToExist(timeout: 20), "A write in Manual Commit must leave its transaction open")

        let rollBack = bar.buttons["Roll Back"].firstMatch
        XCTAssertTrue(waitUntilHittable(rollBack, timeout: 10), "The bar must offer Roll Back")
        rollBack.click()
        let confirm = window.sheets.buttons["Roll Back"].firstMatch
        XCTAssertTrue(waitUntilHittable(confirm, timeout: 10), "Roll Back must ask first")
        confirm.click()

        XCTAssertTrue(bar.waitForNonExistence(timeout: 20), "Rolling back must end the transaction the bar shows")
        let rows = FixtureFile.rows("SELECT body FROM note WHERE id = 1", in: launch.database)
        XCTAssertEqual(rows, [["Buy milk"]], "The rolled-back UPDATE must leave the row as it was")
    }
}
