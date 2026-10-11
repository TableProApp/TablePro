//
//  JSONRowInspectorUITests.swift
//  TableProUITests
//
//  The JSON tab shows the selected row as JSON, a foreign key in it fetches the row it
//  references, and a value that is a link offers to open it. Chinook's Album.ArtistId is the
//  reference this drives.
//

import AppKit
import XCTest

final class JSONRowInspectorUITests: UITestCase {
    func testShowRowAsJSONOpensTheInspectorOnTheJSONTab() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        let grid = try albumGrid(in: app, window: window)

        openRowAsJSON(in: window, grid: grid)

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.jsonTab(in: window).exists },
            "Show Row as JSON must reveal the inspector's JSON tab"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { window.staticTexts["\"Title\""].exists },
            "The JSON tab must print the row's own keys; Album has a Title column"
        )
    }

    func testExpandingAForeignKeyFetchesTheRowItReferences() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        let grid = try albumGrid(in: app, window: window)

        openRowAsJSON(in: window, grid: grid)

        /// Album's own keys hold no container, so the only closed disclosure in the tree is the
        /// foreign key on ArtistId. Its expansion is a query, which is the whole point of the test.
        let expand = window.buttons["Expand"]
        XCTAssertTrue(
            expand.waitToExist(timeout: 20),
            "A foreign key column must offer a disclosure control of its own"
        )
        clickAtCenter(expand)

        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.staticTexts["\"Name\""].exists },
            "Expanding Album.ArtistId must fetch the Artist row, whose columns include Name"
        )
    }

    /// Chinook holds no address, so the row comes from a database the test builds. Six rows, so
    /// the point `openRowAsJSON` clicks lands on one whichever row that is.
    private static let bookmarks = """
    CREATE TABLE bookmark (id INTEGER PRIMARY KEY, site TEXT);
    INSERT INTO bookmark (site) VALUES
        ('https://example.com/docs/1'), ('https://example.com/docs/2'), ('https://example.com/docs/3'),
        ('https://example.com/docs/4'), ('https://example.com/docs/5'), ('https://example.com/docs/6');
    """

    func testALinkValueOffersOpenLinkInItsRowMenu() throws {
        try seedSQLiteSession(connectionNames: ["Bookmarks"], databaseSQL: Self.bookmarks)
        let app = try launchApp()
        let window = app.windows.firstMatch

        let table = objectBrowserRow("bookmark", in: window)
        XCTAssertTrue(table.waitToExist(timeout: 60), "The restored connection must list bookmark")
        clickAtCenter(table)

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "bookmark produced no data grid")
        XCTAssertTrue(
            waitForClickableRows(in: grid),
            "bookmark must load rows before a row can be inspected"
        )

        openRowAsJSON(in: window, grid: grid)

        /// Selectable text publishes the key twice, nested, so a coordinate needs one of them.
        let key = window.staticTexts["\"site\""].firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { key.exists },
            "The JSON tab must print the site column"
        )

        /// A right-click on selectable text raises the text's own menu, measured. The row's menu
        /// answers on the row around it, and the gutter left of the key is row and nothing else.
        key.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: -7, dy: 0))
            .rightClick()

        /// Found, never clicked: the default opener would hand the address to the browser.
        XCTAssertTrue(
            contextMenuItem("Open Link", in: app).waitToExist(timeout: 15),
            "A value that is a link must offer Open Link in its row's menu"
        )
        XCTAssertTrue(
            contextMenuItem("Copy Link", in: app).exists,
            "A value that is a link must offer Copy Link beside Open Link"
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Helpers

    private func readyWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.matching(NSPredicate(format: "identifier != %@", "welcome")).firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 60), "The sample database produced no window")
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.outlines.firstMatch.outlineRows.count > 1 },
            "The object browser must list the sample database's tables"
        )
        return window
    }

    private func albumGrid(in app: XCUIApplication, window: XCUIElement) throws -> XCUIElement {
        let row = window.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value == %@", "Table: Album"))
            .firstMatch
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list Album")
        clickAtCenter(row)

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "Album produced no data grid")
        XCTAssertTrue(
            waitForClickableRows(in: grid),
            "Album must load rows before a row can be inspected"
        )
        return grid
    }

    /// The grid publishes a column as a sibling of its rows, each as tall as every row it spans, so
    /// XCUITest reads every row and cell as obscured and refuses to click one. A point offset from
    /// the grid itself is the way in, which is what the drawn-cell grid's other suites do too.
    ///
    /// `dy` has to clear the header, which the grid draws at 42pt to fit a column comment. A point
    /// inside it opens the header's own column menu, which offers no row command at all. `dx` comes
    /// from `gridPoint`, which clears the object browser: the browser overlaps the grid's leading
    /// edge on the 1024x768 runner, so a fixed offset right-clicks the browser and opens its menu
    /// instead of the row's.
    private func openRowAsJSON(in window: XCUIElement, grid: XCUIElement) {
        let firstRow = gridPoint(in: grid, of: window, dy: 70)
        firstRow.click()
        Thread.sleep(forTimeInterval: NSEvent.doubleClickInterval)
        firstRow.rightClick()

        /// A contextual menu opens inside the window and the menu-bar menus hang off `MenuBar`, so
        /// scoping to the window isolates the one that just opened rather than searching both.
        ///
        /// The item is matched across the window's menus rather than inside `menus.firstMatch`:
        /// every inspector field now draws its own value menu, so the first menu under the window
        /// is no longer reliably the contextual one that just opened.
        let item = window.menus.menuItems["Show Row as JSON"].firstMatch
        XCTAssertTrue(item.waitToExist(timeout: 15), "The row's context menu must offer Show Row as JSON")
        item.click()
    }

    /// The JSON rendering's own filter field, which only that rendering draws. The Fields / JSON
    /// choice moved into the pane header's menu, where it is not on screen to be found, so the test
    /// asks for the rendering it selects rather than for the control that selected it.
    private func jsonTab(in window: XCUIElement) -> XCUIElement {
        window.searchFields["json-row-filter"]
    }
}
