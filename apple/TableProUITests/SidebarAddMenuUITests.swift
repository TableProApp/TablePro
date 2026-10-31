import XCTest

final class SidebarAddMenuUITests: UITestCase {
    func testCreatingATableFromTheSidebar() throws {
        let launch = try launchWithFixture()
        let app = launch.app
        let window = launch.window

        // Scoped to the button: the Database menu carries the same titles.
        let add = window.descendants(matching: .any).matching(identifier: "sidebar-add").firstMatch
        XCTAssertTrue(waitUntilHittable(add, timeout: 30), "The Tables tab carries an add button at its foot")
        add.click()
        let newTable = add.menuItems["New Table…"].firstMatch
        XCTAssertTrue(newTable.waitToExist(timeout: 10), "The add button offers New Table…")
        newTable.click()

        let name = window.textFields["create-table-name"]
        XCTAssertTrue(name.waitToExist(timeout: 30), "New Table… from the add button opens the Create Table tab")
        let validation = window.descendants(matching: .any).matching(identifier: "create-table-validation").firstMatch
        XCTAssertTrue(validation.waitToExist(timeout: 10), "A draft that cannot run yet must say what is missing")

        XCTAssertTrue(waitUntilHittable(name, timeout: 10))
        name.click()
        name.typeText("playlist")

        fillFirstColumn(named: "title", type: "TEXT", in: window, app: app)

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !validation.exists },
            "A named table with a named, typed column has nothing left to fix"
        )
        // Create Table has no button of its own: the toolbar's commit item and Cmd+S run it.
        app.typeShortcut(.save)

        XCTAssertTrue(
            objectBrowserRow("playlist", in: window).waitToExist(timeout: 30),
            "The new table must be listed in the sidebar"
        )
        XCTAssertEqual(
            FixtureFile.rows("SELECT name FROM pragma_table_info('playlist')", in: launch.database),
            [["title"]],
            "The table must be in the file with the column the draft named"
        )
    }

    // Cells are drawn, not mounted, so the row is reached through a point and edited from the keyboard:
    // Left until the cursor stops on the first column, Return opens its editor, Tab commits and opens the next.
    private func fillFirstColumn(named column: String, type: String, in window: XCUIElement, app: XCUIApplication) {
        let columns = window.descendants(matching: .any).matching(identifier: "structure-section-columns").firstMatch
        XCTAssertTrue(columns.waitToExist(timeout: 10), "The Definition page lists the draft's columns")
        let grid = dataGrid(in: columns)
        XCTAssertTrue(waitForClickableRows(in: grid), "The draft starts with one empty column row")
        let firstRow = grid.tableRows.firstMatch
        gridPoint(in: grid, of: window, dy: firstRow.frame.midY - grid.frame.minY).click()
        for _ in 0 ..< 12 {
            app.typeKey(.leftArrow, modifierFlags: [])
        }
        app.typeKey(.return, modifierFlags: [])
        app.typeText(column)
        app.typeKey(.tab, modifierFlags: [])
        app.typeText(type)
        app.typeKey(.return, modifierFlags: [])
    }
}
