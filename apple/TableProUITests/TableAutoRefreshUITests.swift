import XCTest

final class TableAutoRefreshUITests: UITestCase {
    func testAutoRefreshShowsAWriteMadeElsewhereWithoutARefresh() throws {
        let (launch, grid) = try launchWithFixtureTable("document")
        let window = launch.window
        XCTAssertTrue(grid.waitForValue("First", row: 1, column: 2), "document must open on its first row")

        let control = window.descendants(matching: .any).matching(identifier: "result-status-auto-refresh").firstMatch
        XCTAssertTrue(waitUntilHittable(control, timeout: 20), "A table tab's status bar must offer Auto Refresh")
        control.click()
        let everyFiveSeconds = control.menuItems["Every 5 Seconds"].firstMatch
        XCTAssertTrue(everyFiveSeconds.waitToExist(timeout: 10), "Auto Refresh must list Every 5 Seconds")
        everyFiveSeconds.click()

        XCTAssertTrue(
            FixtureFile.execute("UPDATE document SET label = 'Written Elsewhere' WHERE id = 1", in: launch.database),
            "The fixture file must take the write"
        )
        XCTAssertTrue(
            grid.waitForValue("Written Elsewhere", row: 1, column: 2, timeout: 30),
            "Auto Refresh must show the write with no Refresh, the grid shows "
                + "'\(grid.value(row: 1, column: 2) ?? "nil")'"
        )
    }
}
