//
//  TableChangeReloadUITests.swift
//  TableProUITests
//
//  A change to a table used to reach only whichever tab each window had in front. A save announced
//  nothing at all, so a second tab on the same table went on showing the rows from before it, and a
//  structure save reloaded nothing behind the Structure view, so switching back to Data showed the
//  old columns. Neither tab reloaded when shown: each already held rows and had run its query.
//

import AppKit
import XCTest

final class TableChangeReloadUITests: UITestCase {
    /// Chinook has no small table a test can write to without leaving the edit for the next case, so
    /// the app seeds this one afresh at every launch. Both sides spell the name out because a UI test
    /// target cannot import the app.
    private let fixtureVariable = "TABLEPRO_UI_TEST_SEED_JSON_TABLE"
    private let fixtureTable = "json_fixture"
    private let labelColumnPosition = 2
    private let savedValue = "Saved Elsewhere"
    private let heldValue = "Held Here"
    private let addedColumn = "added_col"
    private let otherTable = "MediaType"

    /// The first tab is sorted by `id` descending and the second is not, so the two show the edited
    /// row at different positions. Row 2 of the first tab reads the saved value only once that tab
    /// has fetched again; the second tab's row 2 never holds it, so a grid still painting the second
    /// tab for a moment after the switch cannot pass this.
    func testASaveInOneTabReachesAnotherTabOnTheSameTable() throws {
        let app = try launchWithSampleDatabase(environment: [fixtureVariable: "1"])
        let window = app.windows.firstMatch
        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        let tableRow = openFixtureTable(in: window, grid: grid)

        try clickHeader("id", in: grid)
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.label(row: 1, in: grid) == "First" },
            "The first click sorts ascending"
        )
        try clickHeader("id", in: grid)
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.label(row: 1, in: grid) == "Second" },
            "The second click sorts descending, which puts the row this test edits second"
        )

        tableRow.rightClick()
        let openInNewTab = app.menuItems["Open in New Tab"].firstMatch
        XCTAssertTrue(openInNewTab.waitToExist(timeout: 15), "The sidebar must offer Open in New Tab")
        openInNewTab.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.fixtureTabs(in: window).count == 2 },
            "Open in New Tab must add a second tab on the same table"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                self.label(row: 1, in: grid) == "First" && self.label(row: 2, in: grid) == "Second"
            },
            "The second tab opens unsorted"
        )

        editCell(row: 1, column: labelColumnPosition, in: grid, app: app, to: savedValue)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.label(row: 1, in: grid) == self.savedValue },
            "The edit must land in the second tab"
        )
        app.typeKey("s", modifierFlags: .command)
        /// The save reloads the tab that made it, so its edited cell settles on the stored value.
        _ = waitForPredicate(timeout: 5) { false }

        let firstTab = fixtureTabs(in: window).element(boundBy: 0)
        XCTAssertTrue(firstTab.waitToExist(timeout: 10), "The first tab must still be in the strip")
        clickAtCenter(firstTab)

        XCTAssertTrue(
            waitForPredicate(timeout: 30) { self.label(row: 2, in: grid) == self.savedValue },
            "The first tab must show the saved value without a refresh, it shows "
                + "'\(label(row: 2, in: grid) ?? "nil")'"
        )
        XCTAssertEqual(label(row: 1, in: grid), "Second", "The first tab must keep its own sort across the reload")
    }

    func testAColumnAddedInTheStructureViewShowsInTheDataView() throws {
        let app = try launchWithSampleDatabase(environment: [fixtureVariable: "1"])
        let window = app.windows.firstMatch
        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        _ = openFixtureTable(in: window, grid: grid)
        XCTAssertTrue(header("label", in: grid).waitToExist(timeout: 30), "The Data view must show the fixture's columns")

        showStructure(in: app, window: window)
        addColumnAndSave(in: window, grid: grid, app: app)

        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["View"].menuItems["Data"].click()

        XCTAssertTrue(
            header(addedColumn, in: grid).waitToExist(timeout: 30),
            "Back on Data, the grid must show the column the Structure view added, without a refresh"
        )
    }

    /// The first tab is left on its structure's DDL, which is not one of the sub-tabs a mount
    /// fetches to baseline the editor. Showing it again does not change the selection either, so
    /// nothing fetched the DDL after the other tab's save and it went on showing the old table.
    func testAColumnAddedInAnotherTabShowsInTheDDLThisTabLeftOpen() throws {
        let app = try launchWithSampleDatabase(environment: [fixtureVariable: "1"])
        let window = app.windows.firstMatch
        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        let tableRow = openFixtureTable(in: window, grid: grid)

        showStructure(in: app, window: window)
        let ddlTab = structureSubTab(named: "DDL", in: window)
        XCTAssertTrue(ddlTab.waitToExist(timeout: 20), "The structure editor must offer a DDL sub-tab")
        ddlTab.click()
        XCTAssertTrue(
            ddlText(containing: fixtureTable, in: window).waitToExist(timeout: 30),
            "The DDL sub-tab must show the fixture's CREATE TABLE"
        )
        XCTAssertFalse(ddlText(containing: addedColumn, in: window).exists, "The fixture starts without the column")

        tableRow.rightClick()
        let openInNewTab = app.menuItems["Open in New Tab"].firstMatch
        XCTAssertTrue(openInNewTab.waitToExist(timeout: 15), "The sidebar must offer Open in New Tab")
        openInNewTab.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.fixtureTabs(in: window).count == 2 },
            "Open in New Tab must add a second tab on the same table"
        )
        XCTAssertTrue(waitForClickableRows(in: grid), "The second tab must load its rows")

        showStructure(in: app, window: window)
        addColumnAndSave(in: window, grid: grid, app: app)

        let firstTab = fixtureTabs(in: window).element(boundBy: 0)
        XCTAssertTrue(firstTab.waitToExist(timeout: 10), "The first tab must still be in the strip")
        clickAtCenter(firstTab)

        XCTAssertTrue(
            ddlText(containing: addedColumn, in: window).waitToExist(timeout: 30),
            "Back on the first tab, its DDL must show the column the other tab added, without a refresh"
        )
    }

    /// The first tab holds a staged column in its Structure view while the second adds another and
    /// saves. Fetching that change would throw the staged column away, so it has to wait until the
    /// column is gone, and it used to be dropped instead: the first tab went back to the columns it
    /// had before the save and staged its next edit against them. The staged column is removed with
    /// the footer's remove button rather than undone, because switching tabs resets the window's
    /// undo stack, so Cmd+Z after coming back reaches nothing.
    func testAColumnAddedInAnotherTabShowsOnceThisTabRemovesItsStagedColumn() throws {
        let app = try launchWithSampleDatabase(environment: [fixtureVariable: "1"])
        let window = app.windows.firstMatch
        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        let tableRow = openFixtureTable(in: window, grid: grid)

        showStructure(in: app, window: window)
        let add = window.buttons["structure-footer-add"].firstMatch
        XCTAssertTrue(add.waitToExist(timeout: 20), "The Columns tab must offer an add button")
        XCTAssertTrue(waitForPredicate(timeout: 10) { add.isEnabled }, "SQLite adds a column with ALTER TABLE")
        add.click()
        let stagedRow = 4
        XCTAssertTrue(
            cellElement(row: stagedRow, column: 1, in: grid).waitToExist(timeout: 10),
            "Adding a column stages a fourth row under the fixture's three"
        )

        openSecondFixtureTab(from: tableRow, in: window, grid: grid, app: app)
        showStructure(in: app, window: window)
        addColumnAndSave(in: window, grid: grid, app: app)

        let firstTab = fixtureTabs(in: window).element(boundBy: 0)
        XCTAssertTrue(firstTab.waitToExist(timeout: 10), "The first tab must still be in the strip")
        clickAtCenter(firstTab)
        XCTAssertTrue(
            cellElement(row: stagedRow, column: 1, in: grid).waitToExist(timeout: 20),
            "The first tab keeps its staged column across the other tab's save"
        )
        XCTAssertNotEqual(value(row: stagedRow, column: 1, in: grid), addedColumn, "Nothing is fetched over a staged edit")

        point(at: cellElement(row: stagedRow, column: 1, in: grid).frame, in: grid).click()
        let remove = window.buttons["structure-footer-remove"].firstMatch
        XCTAssertTrue(remove.waitToExist(timeout: 10), "The Columns tab must offer a remove button")
        XCTAssertTrue(waitForPredicate(timeout: 10) { remove.isEnabled }, "Removing the staged column must be offered")
        remove.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 30) { self.value(row: stagedRow, column: 1, in: grid) == self.addedColumn },
            "Once its staged column is removed, the first tab must show the column the other tab added, it shows "
                + "'\(value(row: stagedRow, column: 1, in: grid) ?? "nil")'"
        )
    }

    /// An undo only reaches the tab it was made in while that tab stays in front, since a switch
    /// resets the window's undo stack, so the save comes from a second window. The tab holding the
    /// edit keeps its rows through the save, and used to keep them after the edit was undone too:
    /// only Discard resumed the reload the edit had put off.
    func testUndoingTheLastEditReloadsRowsSavedInAnotherWindow() throws {
        let app = try launchWithSampleDatabase(environment: [fixtureVariable: "1"])
        let firstWindow = app.windows.firstMatch
        let firstGrid = firstWindow.tables.matching(identifier: "data-grid").firstMatch
        let tableRow = openFixtureTable(in: firstWindow, grid: firstGrid)
        openSecondFixtureTab(from: tableRow, in: firstWindow, grid: firstGrid, app: app)

        /// A third table in front of the first window gives the two windows different titles, which
        /// is how the Window menu tells them apart.
        let otherRow = objectBrowserRow(otherTable, in: firstWindow)
        XCTAssertTrue(otherRow.waitToExist(timeout: 20), "The object browser must list \(otherTable)")
        otherRow.rightClick()
        let openOther = app.menuItems["Open in New Tab"].firstMatch
        XCTAssertTrue(openOther.waitToExist(timeout: 15), "The sidebar must offer Open in New Tab")
        openOther.click()
        XCTAssertTrue(waitForClickableRows(in: firstGrid), "\(otherTable) must load its rows")

        let editingTab = fixtureTabs(in: firstWindow).element(boundBy: 0)
        XCTAssertTrue(waitUntilHittable(editingTab, timeout: 20), "The first fixture tab must be hittable")
        editingTab.rightClick()
        let moveItem = app.menuItems.matching(identifier: "Move Tab to New Window").firstMatch
        XCTAssertTrue(moveItem.waitToExist(timeout: 5), "The tab menu must offer Move Tab to New Window")
        moveItem.click()
        XCTAssertTrue(waitForPredicate(timeout: 20) { app.windows.count >= 2 }, "The move must open a second window")

        let editingWindow = app.windows.matching(NSPredicate(format: "title CONTAINS %@", fixtureTable)).firstMatch
        let editingGrid = editingWindow.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(waitForClickableRows(in: editingGrid), "The moved tab must load its rows in its own window")
        editCell(row: 1, column: labelColumnPosition, in: editingGrid, app: app, to: heldValue)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.label(row: 1, in: editingGrid) == self.heldValue },
            "The edit must land in the moved tab"
        )

        bringToFront(windowTitled: otherTable, in: app)
        let savingWindow = app.windows.containing(.any, identifier: "editor-tab").firstMatch
        let savingGrid = savingWindow.tables.matching(identifier: "data-grid").firstMatch
        let savingTab = fixtureTabs(in: savingWindow).firstMatch
        XCTAssertTrue(waitUntilHittable(savingTab, timeout: 20), "The first window must keep the second fixture tab")
        clickAtCenter(savingTab)
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { self.label(row: 2, in: savingGrid) == "Second" },
            "The second fixture tab opens unsorted"
        )
        editCell(row: 2, column: labelColumnPosition, in: savingGrid, app: app, to: savedValue)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { self.label(row: 2, in: savingGrid) == self.savedValue },
            "The save must land in the second fixture tab"
        )
        let otherTab = savingWindow.descendants(matching: .any)
            .matching(identifier: "editor-tab")
            .matching(NSPredicate(format: "label == %@", otherTable))
            .firstMatch
        clickAtCenter(otherTab)

        bringToFront(windowTitled: fixtureTable, in: app)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.label(row: 1, in: editingGrid) == self.heldValue },
            "The moved tab keeps its edit across the other window's save"
        )
        XCTAssertEqual(label(row: 2, in: editingGrid), "Second", "Nothing reloads over an unsaved edit")

        app.typeKey("z", modifierFlags: .command)

        XCTAssertTrue(
            waitForPredicate(timeout: 30) { self.label(row: 2, in: editingGrid) == self.savedValue },
            "Once its edit is undone, the moved tab must show the other window's save, it shows "
                + "'\(label(row: 2, in: editingGrid) ?? "nil")'"
        )
        XCTAssertEqual(label(row: 1, in: editingGrid), "First", "The undo must put the edited cell back")
    }

    // MARK: - Helpers

    private func openSecondFixtureTab(
        from tableRow: XCUIElement,
        in window: XCUIElement,
        grid: XCUIElement,
        app: XCUIApplication
    ) {
        tableRow.rightClick()
        let openInNewTab = app.menuItems["Open in New Tab"].firstMatch
        XCTAssertTrue(openInNewTab.waitToExist(timeout: 15), "The sidebar must offer Open in New Tab")
        openInNewTab.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.fixtureTabs(in: window).count == 2 },
            "Open in New Tab must add a second tab on the same table"
        )
        XCTAssertTrue(waitForClickableRows(in: grid), "The second tab must load its rows")
    }

    /// The Window menu lists every open window by title and is reachable however the windows
    /// overlap, which a click on a window behind another is not.
    private func bringToFront(windowTitled title: String, in app: XCUIApplication) {
        let windowMenu = app.menuBars.firstMatch.menuBarItems["Window"]
        XCTAssertTrue(windowMenu.waitToExist(timeout: 20), "The app must publish its Window menu")
        windowMenu.click()
        let item = windowMenu.menuItems.matching(NSPredicate(format: "title CONTAINS %@", title)).firstMatch
        XCTAssertTrue(item.waitToExist(timeout: 10), "The Window menu must list the window showing \(title)")
        item.click()
    }

    private func addColumnAndSave(in window: XCUIElement, grid: XCUIElement, app: XCUIApplication) {
        let add = window.buttons["structure-footer-add"].firstMatch
        XCTAssertTrue(add.waitToExist(timeout: 20), "The Columns tab must offer an add button")
        XCTAssertTrue(waitForPredicate(timeout: 10) { add.isEnabled }, "SQLite adds a column with ALTER TABLE")
        add.click()

        let newRow = 4
        XCTAssertTrue(
            cellElement(row: newRow, column: 1, in: grid).waitToExist(timeout: 10),
            "Adding a column stages a fourth row under the fixture's three"
        )
        editCell(row: newRow, column: 1, in: grid, app: app, to: addedColumn)
        editCell(row: newRow, column: 2, in: grid, app: app, to: "TEXT")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.value(row: newRow, column: 2, in: grid) == "TEXT" },
            "The new column must carry a type, it has '\(value(row: newRow, column: 2, in: grid) ?? "nil")'"
        )

        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { !app.sheets.firstMatch.exists && !window.sheets.firstMatch.exists }
                && waitForPredicate(timeout: 30) { !(self.value(row: newRow, column: 1, in: grid) ?? "").isEmpty },
            "The save must go through without a sheet"
        )
        _ = waitForPredicate(timeout: 3) { false }
    }

    /// The sub-tab labels carry item counts, so they are matched by prefix rather than exactly.
    private func structureSubTab(named name: String, in window: XCUIElement) -> XCUIElement {
        window.radioGroups["structure-tab-picker"].firstMatch
            .radioButtons
            .matching(NSPredicate(format: "label BEGINSWITH %@", name))
            .firstMatch
    }

    private func ddlText(containing text: String, in window: XCUIElement) -> XCUIElement {
        window.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
    }

    private func openFixtureTable(in window: XCUIElement, grid: XCUIElement) -> XCUIElement {
        let tableRow = objectBrowserRow(fixtureTable, in: window)
        XCTAssertTrue(tableRow.waitToExist(timeout: 30), "The seeded fixture table must appear in the object browser")
        tableRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        Thread.sleep(forTimeInterval: NSEvent.doubleClickInterval)
        XCTAssertTrue(waitForClickableRows(in: grid), "The fixture table must load its rows")
        return tableRow
    }

    /// The sample opens `Track` in a tab of its own, so the fixture's tabs are picked out by title.
    private func fixtureTabs(in window: XCUIElement) -> XCUIElementQuery {
        window.descendants(matching: .any)
            .matching(identifier: "editor-tab")
            .matching(NSPredicate(format: "label == %@", fixtureTable))
    }

    private func header(_ column: String, in grid: XCUIElement) -> XCUIElement {
        grid.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Column: \(column)"))
            .firstMatch
    }

    /// A header is clicked through a coordinate taken off the grid. XCUITest reports the header
    /// element as never hittable however long it waits, and clicks the same point fine.
    private func clickHeader(_ column: String, in grid: XCUIElement) throws {
        let header = header(column, in: grid)
        XCTAssertTrue(header.waitToExist(timeout: 30), "The grid must publish an \(column) header")
        let frame = header.frame
        XCTAssertTrue(frame.width > 0, "The \(column) header must be laid out")
        point(at: frame, in: grid).click()
    }

    private func editCell(row: Int, column: Int, in grid: XCUIElement, app: XCUIApplication, to value: String) {
        let cell = cellElement(row: row, column: column, in: grid)
        XCTAssertTrue(cell.waitToExist(timeout: 10), "Row \(row) must publish its cells")
        point(at: cell.frame, in: grid).click()
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        app.typeKey("a", modifierFlags: .command)
        app.typeText(value)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    }

    private func point(at frame: CGRect, in grid: XCUIElement) -> XCUICoordinate {
        let origin = grid.frame.origin
        return grid.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - origin.x, dy: frame.midY - origin.y))
    }

    /// A cell with a picker publishes as a combo box and a plain one as static text, so both are
    /// found by the identifier they share.
    private func cellElement(row: Int, column: Int, in grid: XCUIElement) -> XCUIElement {
        grid.descendants(matching: .any)
            .matching(identifier: "DataGridCellAccessibilityView")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Row \(row), column \(column): "))
            .firstMatch
    }

    private func value(row: Int, column: Int, in grid: XCUIElement) -> String? {
        let cell = cellElement(row: row, column: column, in: grid)
        guard cell.exists else { return nil }
        return cell.value as? String
    }

    private func label(row: Int, in grid: XCUIElement) -> String? {
        value(row: row, column: labelColumnPosition, in: grid)
    }
}
